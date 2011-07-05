package Oilert::Notifier;
use 5.12.0;
use Dancer ':syntax';
use methods;
use Moose;
use YAML qw/LoadFile/;
use Oilert::Redis;
use WWW::Shorten 'Googl';
use FindBin;
use Net::Twitter;
use LWP::Simple qw/get/;
use URI::Encode qw/uri_encode/;

has 'config' => (is => 'ro', isa => 'HashRef', lazy_build => 1);
has 'twitter' => (is => 'ro', isa => 'Net::Twitter', lazy_build => 1);
has 'redis'  => (is => 'ro', isa => 'Oilert::Redis', lazy_build => 1);

method check {
    my $data = shift;

    my @to_notify;
    my %seen;
    for my $type (keys %$data) {
        next unless ref($data->{$type});
        for my $ship (@{ $data->{$type} }) {
            $seen{ $ship->{mmsi} } ||= $ship;
#            say "Checking $ship->{name} ... $ship->{detail_url}";
            if ($self->redis->sismember("ships_in_bi", $ship->{mmsi})) {
                # ship was already in BI
                my $prev_state = $self->redis->get_json($ship->{mmsi});

                # Check if it stopped or started moving
                my $is_moving = $ship->{speed} > 0.5;
                my $was_moving = $prev_state->{speed} > 0.5;
                my $reason;
                if ($is_moving and not $was_moving) {
                    $reason = "started moving";
                }
                elsif ($was_moving and not $is_moving) {
                    $reason = "stopped moving";
                }
                if ($reason) {
                    push @to_notify, {
                        reason => $reason,
                        ship => $ship,
                    };
                }
            }
            else {
                # Just came into BI - notify
                push @to_notify, {
                    reason => "entered the Burrard Inlet",
                    ship   => $ship,
                };
                $self->redis->sadd("ships_in_bi", $ship->{mmsi});
            }

            # Regardless, update the ship's state
            $self->redis->set_json($ship->{mmsi}, $ship);
        }
    }

    my @all_known = $self->redis->smembers("ships_in_bi");
    for my $mmsi (@all_known) {
        next if $seen{$mmsi};

        # This ship wasn't seen, so it has left the BI
        push @to_notify, {
            reason => "left the Burrard Inlet",
            ship => $self->redis->get_json($mmsi),
        };
        $self->redis->srem('ships_in_bi', $mmsi);
    }

    return \@to_notify;
}

method notify {
    my $notif = shift;
    my $ship = $notif->{ship};
    my $reason = $notif->{reason};
    my $link = makeashorterlink($ship->{detail_url});
    my $msg = "Ship '$ship->{name}' $reason - $link";

    $self->twitter->update({
        status => $msg, 
        lat => $ship->{lat},
        long => $ship->{lng}
    });

    my @recipients = $self->redis->smembers('notify');
    if (!@recipients) {
        warn "No recipients to notify about $reason!";
        return;
    }
    for my $to (@recipients) {
        warn "Notifying $to about $ship->{name}\n";
        $self->send_sms_to( $to, $msg);
    }
}

method send_sms_to {
    my $to = shift;
    my $body = shift;

    $to =~ s/^\+1//;
    my $token = $self->config->{tropo_app_token};
    my $uri = "http://api.tropo.com/1.0/sessions?action=create&token=$token"
        . "&numberToDial=$to&msg=" . uri_encode($body, 1);
    debug "Fetching $uri";
    get($uri) or die "Couldn't fetch $uri";
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
