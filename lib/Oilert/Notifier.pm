package Oilert::Notifier;
use 5.12.0;
use Dancer ':syntax';
use Moose;
use YAML qw/LoadFile/;
use Oilert::Redis;
use WWW::Shorten 'Googl';
use FindBin;
use Net::Twitter;
use LWP::Simple ();
use URI::Encode qw/uri_encode/;
use methods;
use DateTime;

has 'config' => (is => 'ro', isa => 'HashRef', lazy_build => 1);
has 'twitter' => (is => 'ro', isa => 'Maybe[Net::Twitter]', lazy_build => 1);
has 'redis'  => (is => 'ro', isa => 'Oilert::Redis', lazy_build => 1);

method check {
    my $data = shift;

    my @to_notify;
    my %seen;
    for my $type (keys %$data) {
        next unless ref($data->{$type});
        for my $ship (@{ $data->{$type} }) {
            my $mmsi = $ship->{mmsi};
            $seen{ $mmsi } ||= $ship;
            debug "Checking $ship->{name} ... $ship->{detail_url}";

            # Notice ships coming into the second narrows
            if (not $self->redis->sismember("ships_in_bi", $mmsi)) {
                # Just came into BI - notify
                push @to_notify, {
                    reason => "entered the Burrard Inlet",
                    ship   => $ship,
                };
                $self->redis->sadd("ships_in_bi", $mmsi);
            }

            # Check for ships filling up at Westridge Marine Terminal
            if ($self->redis->sismember("ships_at_WRMT", $mmsi)) {
                if (!$ship->{near_wrmt}) {
                    # Ship has just left westridge marine terminal
                    $ship->{full_of_oil}++;
                    my @tides = map { $_->hour . ':'. $_->minute . ' ' . $_->day_name } next_ebb_tides();
                    my $ebb_t = join ' or ', @tides;
                    push @to_notify, {
                        reason => "filled up with oil, probably will leave at $ebb_t",
                        ship => $ship,
                    };
                    $self->redis->srem("ships_at_WRMT", $mmsi);
                }
            }
            else {
                if ($ship->{near_wrmt}) {
                    # Ship just arrived at WRMT
                    push @to_notify, {
                        reason => "docked at Westridge",
                        ship => $ship,
                    };
                    $self->redis->sadd("ships_at_WRMT", $mmsi);
                }
            }

            # Remember if the ship filled up already.
            if (my $oldship = $self->redis->get_json($mmsi)) {
                $ship->{full_of_oil} ||= $oldship->{full_of_oil};
            }

            # Regardless, update the ship's state
            $self->redis->set_json($mmsi, $ship);
        }
    }

    my @all_known = $self->redis->smembers("ships_in_bi");
    for my $mmsi (@all_known) {
        next if $seen{$mmsi};
        my $ship = $self->redis->get_json($mmsi);
        my $reason = '';
        $reason = " full of oil" if $ship->{full_of_oil};

        # This ship wasn't seen, so it has left the BI
        push @to_notify, {
            reason => "left the Burrard Inlet$reason",
            ship => $self->redis->get_json($mmsi),
        };
        $self->redis->srem('ships_in_bi', $mmsi);

        # For now, do not remember ships that have left the area.
        $self->redis->del($mmsi);
    }

    return \@to_notify;
}

method notify {
    my $notif = shift;
    my $ship = $notif->{ship};
    my $reason = $notif->{reason};
    my $link = makeashorterlink($ship->{detail_url});
    my $msg = "Ship '$ship->{name}' $reason - $link - Take Action: 604-683-8220";

    debug "Notification: '$msg' (length: " . length($msg). ")";

    $self->twitter->update({
        status => $msg, 
        lat => $ship->{lat},
        long => $ship->{lng}
    }) if $self->twitter;

    my @recipients = $self->redis->smembers('notify');
    if (!@recipients) {
        warn "No recipients to notify about $reason!";
        return;
    }
    for my $to (@recipients) {
        debug "Notifying $to about $ship->{name}\n";
        $self->send_sms_to( $to, $msg);
    }
}

sub next_ebb_tides {
    my $now = DateTime->now;
    $now->set_time_zone('America/Vancouver');

    my $content = LWP::Simple::get(
        'http://tbone.biol.sc.edu/tide/tideshow.cgi?type=table;'
        . 'tplotdir=horiz;cleanout=1;glen=3;'
        . 'site=Second%20Narrows%2C%20British%20Columbia%20Current'
    );
    my @tides;
    for my $line (split "\n", $content) {
        next unless $line =~ m/(\d+)-(\d+)-(\d+)\s+(\d+):(\d+)\s+\w+\s+[\d\-\.]+\s+knots\s+Slack, Ebb Begins$/;
        my $dt = DateTime->new(
            year => $1, month => $2, day => $3,
            hour => $4, minute => $5,
        );
        $dt->set_time_zone('America/Vancouver');

        # Skip high tides that already happened
        next unless $dt > $now;

        # Skip high tides that are at night
        next if $dt->hour < 6 or $dt->hour > 22;

        push @tides, $dt;
        return @tides if @tides == 2;
    }
    return @tides;
}

method send_sms_to {
    my $to = shift;
    my $body = shift;

    $to =~ s/^\+1//;
    my $token = $self->config->{tropo_app_token};
    my $uri = "http://api.tropo.com/1.0/sessions?action=create&token=$token"
        . "&numberToDial=$to&msg=" . uri_encode($body, 1);
    debug "Fetching $uri";
    LWP::Simple::get($uri) or die "Couldn't fetch $uri";
}

method clear_state {
    for my $key ($self->redis->keys('*')) {
        warn "Deleting $key";
        $self->redis->del($key);
    }
}

method _build_config {
    my $file = "/home/dotcloud/services.yaml";
    $file = "$FindBin::Bin/etc/services.yaml" unless -e $file;
    $file = "$FindBin::Bin/../etc/services.yaml" unless -e $file;
    return LoadFile($file) or die "Can't load services config";
}

method _build_twitter {
    return undef unless $self->config->{twitter_username};
    my $t = Net::Twitter->new(
        traits => ['API::REST', 'OAuth'],
        consumer_key => $self->config->{twitter_consumer_key},
        consumer_secret => $self->config->{twitter_consumer_secret},
    );
    $t->access_token($self->config->{twitter_access_token});
    $t->access_token_secret($self->config->{twitter_access_token_secret});
    return $t;
}

method _build_redis { Oilert::Redis->new }
