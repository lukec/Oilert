package Oilert;
use Dancer ':syntax';
use YAML qw/LoadFile/;
use Oilert::Redis;
use Oilert::Notifier;
use Number::Phone;
use DateTime;

our $VERSION = '0.1';

get '/' => sub {
    my $data = ships();
    template 'index', {
        ships => $data->{ships},
        message => params->{message},
        update_time => $data->{update_time},
    };
};

sub ships {
    my $data = LoadFile("data/ships.yaml");
    my $time = DateTime->from_epoch(epoch => $data->{update_time});
    $time->set_time_zone("America/Vancouver");

    return {
        ships => $data->{Tanker} || [],
        update_time => $time,
    };
}

get '/form'  => sub { template 'form', {}, {layout => undef} };
get '/ships' => sub { template 'ships', ships(), {layout => undef} };

get '/blast' => sub {
    my $data = ships();
    debug "GET blast - " . (params->{message} || '');
    use Data::Dumper;
    debug params;
    template 'blast-form', {
        message => params->{ui_message},
    };
};
post '/blast' => sub {
    my $notifier = Oilert::Notifier->new;
    my $ui_message = '';
    
    # TODO check password

    if (my $message = params->{"message"}) {
        $message = substr $message, 0, 140;
        debug "Sending a BLAST to everyone for '$message'";
        $notifier->send_sms_to_all($message);
        $notifier->twitter->update({ status => $message }) if $notifier->twitter;
        $ui_message = "Sent the blast to everyone.";
    }
    else {
        $ui_message = "No message provided.";
    }

    forward '/blast', { ui_message => $ui_message }, { method => 'GET' };
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
