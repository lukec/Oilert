package Oilert;
use Dancer ':syntax';
use Oilert::Notifier;
use Oilert::ShipDatabase;
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
    my $db = Oilert::ShipDatabase->new;
    return {
        ships => $db->ships,
        update_time => $db->last_update,
    };
}

get '/sms'   => sub {
    my $from = params->{from};
    my $msg  = lc params->{msg};
    my $notifier = Oilert::Notifier->new;
    if ($msg and $from) {
        $from =~ s/^\+?1?//;
        $from = "+1" . $from;
        if ($msg =~ m/^(stop|quit|leave|exit)/) {
            debug "Stopping sending to $from";
            $notifier->remove_subscriber($from);
        }
        elsif ($msg =~ m/^(yes|start|go|sub|oil)/) {
            $notifier->add_subscriber($from);
        }
        else {
            debug "Unknown command";
        }
    }
    else {
        debug "Invalid SMS request";
    }
    template 'sms-rx', {}, {layout => undef};
};

get '/form'  => sub { template 'form', {}, {layout => undef} };
get '/ships' => sub { template 'ships', ships(), {layout => undef} };

get '/blast' => sub {
    my $data = ships();
    template 'blast-form', {
        message => params->{ui_message},
    };
};
post '/blast' => sub {
    my $notifier = Oilert::Notifier->new;
    my $ui_message = '';
    
    my $pass = params->{"password"} || 'No-password';
    if ($pass ne $notifier->config->{blast_password}) {
        $ui_message = "Invalid password.";
    }
    else {
        if (my $message = params->{"message"}) {
            $message = substr $message, 0, 140;
            debug "Sending a BLAST to everyone for '$message'";
            $notifier->send_sms_to_all($message);
            $notifier->twitter->update({ status => $message })
                if $notifier->twitter and params->{tweet_it};
            my $count = @{ $notifier->sms_recipients };
            $ui_message = "Sent the blast to $count recipients.";
        }
        else {
            $ui_message = "No message provided.";
        }
    }

    forward '/blast', { ui_message => $ui_message }, { method => 'GET' };
};

post '/notify' => sub {
    my $notifier = Oilert::Notifier->new;
    my $message = "No action taken.";
    if (my $start_num = get_number('signup_number')) {
        $message = "Added notifications for $start_num";
        $notifier->add_subscriber($start_num);
    }
    elsif (my $stop_num = get_number('stop_number')) {
        $message = "Stopped notifications for $stop_num";
        $notifier->remove_subscriber($stop_num);
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
