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

method add_subscriber {
    my $num = shift;
    $num =~ s/[^\d\+]//g;
    $self->send_sms_to( $num,
        "You are now subscribed to Burrard Inlet Oil Tanker Traffic notifications. Call 604-683-8220 for help."
    );
    $self->redis->sadd('notify', $num);
};

method remove_subscriber {
    my $num = shift;
    $num =~ s/[^\d\+]//g;
    $self->redis->srem('notify', $num);
    $self->send_sms_to( $num,
        "You are now un-subscribed. Call 604-683-8220 for help."
    );
}

method update {
    if (my $alert = $self->_check(@_)) {
        $self->notify($alert);
    }
}

method _check {
    my ($old_ship, $new_ship) = @_;
    my $mmsi = $new_ship->mmsi;
    my $name = $new_ship->name;
    print " (Checking $name ($mmsi)) ";

    if ($self->redis->sismember("ships_in_bi", $mmsi)) {
        # Notice ships leaving the second narrows
        if (not $new_ship->is_in_binlet) {
            my $reason = '';
            $reason = " full of oil" if $new_ship->has_filled_up;

            $self->redis->srem('ships_in_bi', $mmsi);

            return {
                reason => "left the Burrard Inlet$reason",
                ship => $new_ship,
            };
        }
    }
    else {
        if ($new_ship->is_in_binlet) {
            # Notice ships coming into the second narrows
            # Just came into BI - notify
            $self->redis->sadd("ships_in_bi", $mmsi);
            $new_ship->has_filled_up(0);
            return {
                reason => "entered the Burrard Inlet",
                ship   => $new_ship,
            };
        }
    }

    # Check for ships filling up at Westridge Marine Terminal
    if ($self->redis->sismember("ships_at_WRMT", $mmsi)) {
        if (not $new_ship->is_near_wrmt) {
            warn "Ship was at WRMT but now is not near it: " . $new_ship->location_str;
            # Ship has just left westridge marine terminal
            $new_ship->has_filled_up(1);
            $self->redis->set_json($mmsi, $new_ship->to_hash);

            my @tides = map { $_->hour . ':'. $_->minute . ' ' . $_->day_name }
                        next_ebb_tides();
            my $ebb_t = join ' or ', @tides;
            $self->redis->srem("ships_at_WRMT", $mmsi);
            return {
                reason => "filled up with oil, probably will leave at $ebb_t",
                ship => $new_ship,
            };
        }
        else {
            print " (" . $new_ship->name . " is at WRMT) ";
        }
    }
    else {
        if ($new_ship->is_near_wrmt) {
            # Ship just arrived at WRMT
            $self->redis->sadd("ships_at_WRMT", $mmsi);
            return {
                reason => "docked at Westridge",
                ship => $new_ship,
            };
        }
    }

    return undef;
}

method notify {
    my $notif = shift;
    my $ship = $notif->{ship};
    my $reason = $notif->{reason};
    my $link = makeashorterlink($ship->detail_url);
    my $msg = "Ship '" . $ship->{name} . "' $reason - $link - Take Action: 604-683-8220";

    if (my $prefix = $self->config->{message_prefix}) {
        $msg = $prefix . $msg;
    }
    print " ($msg - " . length($msg) . ") ";

    $self->twitter->update({
        status => $msg, 
        lat => $ship->lat,
        long => $ship->lng
    }) if $self->twitter;

    $self->send_sms_to_all($msg);
}

method send_sms_to_all {
    my $msg = shift;
    my @recipients = $self->redis->smembers('notify');
    for my $to (@recipients) {
        print " (Notifying $to) ";
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
