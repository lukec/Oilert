package Oilert::Notifier;
use 5.12.0;
use methods;
use Moose;
use WWW::Twilio::API;
use YAML qw/LoadFile/;
use Oilert::Redis;
use WWW::Shorten 'Googl';

has 'config' => (is => 'ro', isa => 'HashRef', lazy_build => 1);
has 'twilio' => (is => 'ro', isa => 'WWW::Twilio::API', lazy_build => 1);
has 'redis'  => (is => 'ro', isa => 'Oilert::Redis', lazy_build => 1);

method check {
    my $data = shift;

    my @to_notify;
    my %seen;
    for my $type (keys %$data) {
        next unless ref($data{$type});
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

    my @recipients = $self->redis->smembers('notify');
    if (!@recipients) {
        warn "No recipients to notify about $reason!";
        return;
    }
    for my $to (@recipients) {
        warn "Notifying $to about $ship->{name}\n";
        my $resp = $self->twilio->POST(
            'SMS/Messages',
            From => $self->config->{sms_number},
            To => $to,
            Body => "$ship->{type} ship '$ship->{name}' $reason - $link",
        );
    }
}

method clear_state {
    for my $key ($self->redis->keys('*')) {
        warn "Deleting $key";
        $self->redis->del($key);
    }
}

method _build_config {
    LoadFile('etc/twilio.yaml') or die "Can't load twilio config";
}

method _build_twilio {
    return WWW::Twilio::API->new(
        API_VERSION => '2010-04-01',
        AccountSid => $self->config->{account_sid},
        AuthToken => $self->config->{auth_token},
    );
}

method _build_redis { Oilert::Redis->new }
