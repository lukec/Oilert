package Oilert;
use Dancer ':syntax';
use YAML qw/LoadFile/;
use Oilert::Redis;
use Oilert::Notifier;
use Number::Phone;
use DateTime;

our $VERSION = '0.1';

get '/' => sub {
    my $data = LoadFile("data/ships.yaml");
    my $time = DateTime->from_epoch(epoch => $data->{update_time});
    $time->set_time_zone("America/Vancouver");

    template 'index', {
        ships => [ @{ $data->{Tanker} || [] }, @{ $data->{Cargo} || [] } ],
        message => params->{message},
        update_time => $time,
    };
};

post '/notify' => sub {
    my $redis = Oilert::Redis->new;
    my $notifier = Oilert::Notifier->new;
    my $message = "No action taken.";
    if (my $start_num = get_number('signup_number')) {
        $message = "Added notifications for $start_num";
        $notifier->send_sms_to( $start_num,
            "You are now subscribed to Burrard Inlet Oil Tanker Traffic notifications. Call 604-683-8220 for help."
        );
        $redis->sadd('notify', $start_num);
    }
    elsif (my $stop_num = get_number('stop_number')) {
        $message = "Stopped notifications for $stop_num";
        $redis->srem('notify', $stop_num);
        $notifier->send_sms_to( $stop_num,
            "You are now un-subscribed. Call 604-683-8220 for help."
        );
    }

    forward '/', { message => $message }, { method => 'GET' };
};

sub get_number {
    my $name = shift;
    my $digits = "+1" . params->{$name};
    my $num = Number::Phone->new($digits);
    return $digits if $num and $num->is_valid;
    return undef;
}

true;
