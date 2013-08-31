package Oilert::Notifier;
use 5.10.0;
use Dancer ':syntax';
use Moose;
use Oilert::WorkQueue;
use WWW::Shorten 'Googl';
use Net::Twitter;
use LWP::Simple ();
use DateTime;
use Try::Tiny;
use Oilert::Util qw/email_admin/;
use methods;

has 'twitter' => (is => 'ro', isa => 'Net::Twitter', lazy_build => 1);

with 'Oilert::Base';

method add_subscriber {
    my $num = shift;
    $num =~ s/[^\d\+]//g;
    $self->send_sms_to( $num,
        "You are now subscribed to Burrard Inlet Oil Tanker Traffic notifications. Call 604-683-8220 for more information."
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

            $self->redis->srem('ships_in_bi', $mmsi);

            my $reason = '';
            if ($new_ship->has_filled_up) {
                $reason = "now departing with oil. Take Action: theWC.ca/tankers #OilSpill #Climate #theWC";
            }
            else {
                $reason = "now departing the Burrard Inlet. Take Action: theWC.ca/tankers #Climate #theWC";
            }
            return {
                reason => $reason,
                ship => $new_ship,
                risk => $new_ship->has_filled_up,
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
                reason => "oil tanker entered the Burrard Inlet. Take Action: theWC.ca/Tankers #OilSpill #Climate #YVR #theWC",
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
            $self->redis->srem("ships_at_WRMT", $mmsi);

            my %short_day = (
                monday => 'Mon', tuesday => 'Tues', wednesday => 'Weds', 
                thursday => 'Thurs', friday => 'Fri', saturday => 'Sat', 
                sunday => 'sun',
            );
            # We decided to ignore tides, so we aren't using this data
            # anymore, for now.
#             my @tides = map { $_->hour . ':'. $_->minute . ' ' . $short_day{lc $_->day_name} }
#                         next_ebb_tides();
#             my $ebb_t = join ' or ', @tides;
            return undef;
#             return {
#                 reason => "filled up with oil, will leave soon.",
#                 ship => $new_ship,
#             };
        }
        else {
            print " (" . $new_ship->name . " is at WRMT " . $new_ship->location_str . ") ";
        }
    }
    else {
        if ($new_ship->is_near_wrmt) {
            # Ship just arrived at WRMT
            $self->redis->sadd("ships_at_WRMT", $mmsi);
            return {
                reason => "now at the Kinder Morgan terminal. Take Action: theWC.ca/Tankers #OilSpill #Climate #theWC",
                ship => $new_ship,
                textable => 1,
            };
        }
    }

    if ($new_ship->is_in_webcam_range) {
        my $now = DateTime->now; $now->set_time_zone('America/Vancouver');
        my $webcam_key = $now->ymd . "-" . $new_ship->mmsi;
        if (!$self->redis->sismember(webcam => $webcam_key)) {
            $self->redis->sadd(webcam => $webcam_key);
            return {
                reason => "is in webcam range, please verify if you can",
                ship => $new_ship,
                wc_only => 1,
            };
        }
    }
    return undef;
}

method notify {
    my $notif = shift;
    my $ship = $notif->{ship};
    my $reason = $notif->{reason};
    my $risk   = $notif->{risk_alert};
    my $length = $ship->length ? " ($ship->{length}m)" : '';
    my $msg = "$ship->{name}$length $reason";
    $msg = "RISK ALERT: $msg" if $risk;

    if (my $prefix = $self->config->{message_prefix}) {
        $msg = $prefix . $msg;
    }
    print " ($msg - " . length($msg) . ") ";

    if ($notif->{wc_only}) {
        # This is an internal-only text
        my @recips = split ",", config->{webcam_notif_recips};
        for my $r (@recips) {
            print " (Webcam to $r) ";
            $self->send_sms_to($r, $msg);
        }
        return;
    }

    try {
        $self->twitter->update({
            status => $msg, 
            lat => $ship->lat,
            long => $ship->lon
        }) if $self->twitter;
    }
    catch {
        email_admin("Oilert error: tweeting", $_);
    }

    try {
        # Strip off all hashtags off of the SMS
        (my $sms = $msg) =~ s/\s+#.+$//;
        $self->send_sms_to_all($sms) if $notif->{textable};
    }
    catch {
        email_admin("Oilert error: texting", $_);
    }
}

method sms_recipients {
    return [ $self->redis->smembers('notify') ];
}

method send_sms_to_all {
    my $msg = shift;

    my $now = DateTime->now;
    $now->set_time_zone('America/Vancouver');
    if ($now->hour < 7 or $now->hour > 22) {
        print " (Queue-ing night-time text) ";
        $self->redis->rpush('night-time', $msg);
        return;
    }

    print " (Notification: '$msg') ";
    for my $to (@{ $self->sms_recipients }) {
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

# This method just enqueues the text to be sent - it does not send it.
method send_sms_to {
    my $to = shift;
    my $body = shift;

    $to =~ s/^\+1//;
    Oilert::WorkQueue->new->add({
        type => 'SendSMS',
        to => $to,
        body => $body,
    });
}

method clear_state {
    for my $key ($self->redis->keys('*')) {
        warn "Deleting $key";
        $self->redis->del($key);
    }
}

method _build_twitter {
    return undef unless $self->config->{twitter_username};
    my $t = Net::Twitter->new(
        traits => ['API::RESTv1_1', 'OAuth'],
        consumer_key => $self->config->{twitter_consumer_key},
        consumer_secret => $self->config->{twitter_consumer_secret},
    );
    $t->access_token($self->config->{twitter_access_token});
    $t->access_token_secret($self->config->{twitter_access_token_secret});
    return $t;
}

