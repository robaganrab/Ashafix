package Ashafix::Controller::Virtual;
#===============================================================================
#
#         FILE:  Virtual.pm
#
#  DESCRIPTION:  Virtual domains
#
#       AUTHOR:  Matthias Bethke (mbethke), matthias@towiski.de
#      COMPANY:  Zonarix S.A.
#      VERSION:  1.0
#      CREATED:  09/11/2011 12:49:11 AM
#     REVISION:  ---
#===============================================================================
use 5.010;
use feature qw/switch/;
use Mojo::Base 'Ashafix::Controller';
use List::Util qw/min max/;
use List::MoreUtils qw/any none/;
use Local::AliasStatus;

sub list {
    my $self = shift;
    my $user = $self->auth_get_username;
    my (@allowed_domains, @aliases, @alias_domains, @mailboxes);
    my %divide_quota;
    my ($is_globaladmin, $can_create_alias_domain);
    state $page_size = $self->cfg('page_size');

    # Get all domains for this admin
    @allowed_domains = $self->get_domains_for_user;
    $is_globaladmin = $self->auth_has_role('globaladmin');

    unless(@allowed_domains) {
        # TODO localize
        $self->flash_error($is_globaladmin ? 'no_domains_exist' : 'no_domains_for_this_admin');
        return $self->redirect_to('domain-list');
    }

    my $domain  = lc( $self->param('domain') // $allowed_domains[0]);
    my $display = int($self->param('limit')  // 0);
    my $search  =     $self->param('search');

    unless(any { $_ eq $domain } @allowed_domains) {
        # Domain parameter not in list of allowed domains
        $self->flash_error_l('invalid_parameter');
        return $self->redirect_to('domain-list');
    }

    $self->session(list_virtual_sticky_domain => $domain);

    if($self->cfg('alias_domain')) {
        @alias_domains = $self->model('aliasdomain')->list_paged($domain, $page_size, $display);
        $can_create_alias_domain = none { $_->target_domain eq $domain } @alias_domains;
        # TODO: set $can_create_alias_domain = 0; if all domains (of this admin) are already used as alias domains
    }

    @aliases = $self->model('domain')->list_addresses(
        search  => $search,
        domain  => $domain,
        offset  => $display,
        limit   => $page_size,
        domains => [ @allowed_domains ],
    );

    @mailboxes = $self->model('domain')->list_mailboxes(
            search  => $search,
            domain  => $domain,
            offset  => $display,
            limit   => $page_size,
    );

    if($self->cfg('alias_control_admin')) {
        foreach my $mbox (@mailboxes) {
            $mbox->{goto_mailbox} = 0;
            foreach my $goto (split /,/, $mbox->{goto}) {
                state $vacation = $self->cfg('vacation');
                state $vacation_domain = $self->cfg('vacation_domain');
                state $rec_delim = $self->cfg('recipient_delimiter');

                my $goto_noext = $goto;
                $rec_delim and $goto_noext =~ s/$rec_delim[^$rec_delim\@]*@/\@/o;
                if(any { $_ eq $mbox->{username} } $goto, $goto_noext) {
                    # delivers to mailbox
                    $mbox->{goto_mailbox} = 1;
                } elsif($vacation and index $goto_noext, "\@$vacation_domain") {
                    # vacation alias - TODO check for full vacation alias
                    # skip the vacation alias, vacation status is detected otherwise
                } else {
                    # forwarding to other alias
                    push @{$mbox->{goto_other}}, $goto; 
                }
            }
        }
    }

    # TODO simplify. The _show variables are superfluous
    my ($can_add_alias, $can_add_mailbox,
        $display_back, $display_back_show,
        $display_up_show,
        $display_next, $display_next_show);

    my $dom = $self->model('domain')->load($domain);

    if($display >= $page_size) {
        $display_back_show = 1;
        $display_back = $display - $page_size;
    }
    $display_up_show = ($dom->alias_count > $page_size or $dom->mailbox_count > $page_size);
    if(
        (($display + $page_size) < $dom->alias_count) or
        (($display + $page_size) < $dom->mailbox_count))
    {
        $display_next_show = 1;
        $display_next = $display + $page_size;
    }
    $can_add_alias   = (0 == $dom->aliases   or $dom->alias_count   < $dom->aliases);
    $can_add_mailbox = (0 == $dom->mailboxes or $dom->mailbox_count < $dom->mailboxes);

    if(0 == $dom->mailboxes) {
        $dom->$_($self->eval_size($dom->$_)) foreach(qw/ aliases mailboxes maxquota /);
    }

    foreach my $alias (@aliases) {
        $alias->{gen_status}    = Local::AliasStatus->new($self, $alias->{address});
        $alias->{user_is_owner} = $self->check_alias_owner($self->auth_get_username, $alias->{address});
    }

    foreach my $mbox (@mailboxes) {
        $mbox->{gen_status} = Local::AliasStatus->new($self, $mbox->{username});
        my $dq = $mbox->{divide_quota} = {};
        $dq->{$_} = $self->divide_quota($mbox->{$_}) foreach(qw/ current quota /);
        if(defined $mbox->{quota} and defined $mbox->{current}) {
            $dq->{percent} = min( 100, int( (($dq->{current} / max(1, $dq->{quota})) * 100) + 0.5 ) );
            $dq->{quota_width} = ($dq->{percent} * 1.2); # TODO redundant?
        }
    }
    my %renderargs = (
        domain              => $domain,
        current_limit       => $page_size,
        domains             => \@allowed_domains,
        mailboxes           => \@mailboxes,
        aliases             => \@aliases,
        aliasdomains        => \@alias_domains,
        limit               => $dom,
        can_add_alias       => $can_add_alias,
        can_add_mailbox     => $can_add_mailbox,
        display_back        => $display_back,
        display_back_show   => $display_back_show,
        display_up_show     => $display_up_show,
        display_next        => $display_next,
        display_next_show   => $display_next_show,
        search              => $search,
        #int      highlight_at
    );
#    foreach my $m (@{$renderargs{mailbox}}) {
#        foreach(sort keys %$m) { print "$_ => $m->{$_}\n" }
#        print "\n";
#    }
    $self->render(%renderargs);
}

sub eval_size {
    my ($self, $size) = @_;

    return $self->l('pOverview_unlimited') if $size == 0;
    return $self->l('pOverview_disabled')  if $size < 0;
    return $size;
}

1;
