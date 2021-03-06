package Ashafix::Controller;
#===============================================================================
#
#         FILE:  Controller.pm
#
#  DESCRIPTION:  Base class for all Ashafix controllers. Collects a few
#                utility methods
#
#        FILES:  ---
#         BUGS:  ---
#        NOTES:  ---
#       AUTHOR:  Matthias Bethke (mbethke), matthias@towiski.de
#      COMPANY:  Zonarix S.A.
#      VERSION:  1.0
#      CREATED:  09/12/2011 03:58:21 PM
#     REVISION:  ---
#===============================================================================
use 5.010;
use Mojo::Base 'Mojolicious::Controller';
use URI::Escape;
use Carp;

# Show error/info in page header of current or redirected-to page
sub show_error  { shift->_add_show( error => join('', @_)) }
sub show_info   { shift->_add_show( info  => join('', @_)) }
sub flash_error { shift->_add_flash(error => join('', @_)) }
sub flash_info  { shift->_add_flash(info  => join('', @_)) }
# Localizing versions of the above
sub show_error_l  { shift->_localize(_add_show  => error => @_) }
sub show_info_l   { shift->_localize(_add_show  => info  => @_) }
sub flash_error_l { shift->_localize(_add_flash => error => @_) }
sub flash_info_l  { shift->_localize(_add_flash => info  => @_) }
sub _localize {
    my ($self, $func, $what, $key) = splice @_,0,4;
    $self->$func($what => join('', $self->l($key), @_));
}

sub _add_show   { push @{$_[0]->stash($_[1])}, $_[2] }
sub _add_flash  {
    my ($self, $what, $msg) = @_;
    my $msgs = $self->flash($what) // [];
    $self->flash($what => [@$msgs, $msg]);
}

# Config shortcut
sub cfg { $_[0]->app->config->{$_[1]} }

# Return a localized message for a Mojo::Exception
sub handle_exception {
    my ($self, $e) = @_;
    my $msg = $e->message;

    warn "handle_exception($msg) (ref:`".(ref $msg)."'".(ref $msg?" => [@$msg]":'');
    # Is it a non-ref that just needs to be localized?
    ref $msg eq '' and return $self->l($msg);
    # Should be an array that has an i18n key as the first element and
    # arguments as the rest
    my $localized = shift @$msg;
    # Only localize if not the empty string (dummy for returning untranslated-as-of-yet strings)
    $localized = $self->l($localized) if length $localized;
    # Does it look like an sprintf-style pattern?
    index $localized, '%' and return sprintf($localized, @$msg);
    # No, it doesn't. Just concatenate the stuff
    return join('', $localized, @$msg);
}

# Get the currently logged in user
sub auth_get_username {
    my $user = shift->session('user') or return;
    return $user->name;
}


# Takes a user role and returns a boolean indicating whether current user
# has this role
sub auth_has_role {
    my ($self, $role) = @_;
    my $user = $self->session('user') or return;
    return $user->roles->{$role};
}

# Requires user to have a certain role. On failure, false is returned
# and the user redirected to login
sub auth_require_role {
    my ($self, $role) = @_;
    return unless $self->auth_require_login;
    return 1 if $self->auth_has_role($role);
    # TODO flash() "Insufficient privileges" or something?
    $self->redirect_to(named => 'login', redirect => $self->url_with);
    return;
}

# Require that user be logged in. Redirect to login if not.
sub auth_require_login {
    my $self = shift;
    my $user = $self->session('user');
    return 1 if defined($user) && defined($user->name);
    $self->redirect_to(named => 'login', redirect => $self->url_with);
    return;
}

sub get_domains_for_user {
    my $self = shift;
    $self->model('domain')->list(
        $self->auth_has_role('globaladmin') ? undef : $self->auth_get_username
    );
}

# Recalculate mailbox quota to bytes
sub divide_quota {
    my ($self, $quota) = @_;

    return unless defined $quota;
    return $quota if -1 == $quota;
    return sprintf("%.2d", ($quota / $self->cfg('quota_multiplier')) + 0.05);
}

sub check_domain_owner {
    my ($self, $user, $domain) = @_;

    if($self->auth_has_role('globaladmin')) {
        # Global admins "own" every domain, so just check that domain actually exists
        $self->model('domain')->load($domain) and return 1;
        $self->show_error("Domain `$domain' does not exist");
        return;
    }
    my @doms = $self->schema('domainadmin')->check_domain_owner($user, $domain)->flat->[0] and return 1;
    return;
}

sub check_alias_owner { 
    my ($self, $username, $alias) = @_;

    return 1 if $self->auth_has_role('globaladmin');

    my ($localpart) = split /\@/, $alias;
    return if(!$self->cfg('special_alias_control') and exists $self->cfg('default_aliases')->{$localpart});
    return 1;
}

# Takes a user name and a password and returns a user object 
# or undef on verification failure
sub verify_account {
    my ($self, $user, $pass) = @_;
    my $u;
    return unless defined $user and defined $pass;

    $u = $self->model('admin')->load($user)
        and $self->_compare_passwords($pass, $u->password) and return $u;
    $u = $self->model('mailbox')->load($user)
        and $self->_compare_passwords($pass, $u->password) and return $u;
    return;
}

# Updates a previously loaded user in the database, selecting the correct model
# automatically
# TODO only updates passwords so far! See models.
sub update_user {
    my ($self, $user) = @_;
    $self->model($user->roles->{admin} ? 'admin' : 'mailbox')->update($user);
}

sub _compare_passwords {
    my ($self, $pass_clear, $pass_crypt) = @_;
    return $self->app->pacrypt($pass_clear, $pass_crypt) eq $pass_crypt;
}

# Log actions to database
# Call: db_log (string domain, string action, string data)
# Possible actions are:
# 'create_domain'
# 'create_alias'
# 'create_alias_domain'
# 'create_mailbox'
# 'delete_domain'
# 'delete_alias'
# 'delete_alias_domain'
# 'delete_mailbox'
# 'edit_domain'
# 'edit_alias'
# 'edit_alias_state'
# 'edit_alias_domain_state'
# 'edit_mailbox'
# 'edit_mailbox_state'
# 'edit_password'
#
sub db_log {
    my ($self, $domain, $action, $data) =@_;
    state $logging = $self->cfg('logging');
    state $LOG_ACTIONS = {
        map { $_ => 1 } qw/
        create_alias edit_alias edit_alias_state delete_alias create_mailbox
        edit_mailbox edit_mailbox_state delete_mailbox create_domain edit_domain
        delete_domain create_alias_domain edit_alias_domain_state
        delete_alias_domain edit_password /
    };

    die "Invalid log action `$action'" unless defined $LOG_ACTIONS->{$action};
    return unless $logging;

    my $remote_addr = $self->tx->remote_address;
    my $username = $self->auth_get_username;
    return 1 == $self->model('log')->insert("$username ($remote_addr)", $domain, $action, $data)->rows;
}

# Return a true value if the passed-in user is a global admin
sub _check_global_admin { defined $_[0]->schema('domainadmin')->check_global_admin($_[1])->list }

1;
