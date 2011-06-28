package Oilert;
use Dancer ':syntax';
use YAML qw/LoadFile/;
use Oilert::Redis;
use Number::Phone;

our $VERSION = '0.1';

get '/' => sub {
    my $data = LoadFile("data/ships.yaml");

    template 'index', {
        ships => [ @{ $data->{Tanker} }, @{ $data->{Cargo} } ],
        message => params->{message},
    };
};

post '/notify' => sub {
    my $redis = Oilert::Redis->new;
    my $message = "No action taken.";
    if (my $start_num = get_number('signup_number')) {
        $message = "Added notifications for $start_num";
        $redis->sadd('notify', $start_num);
    }
    elsif (my $stop_num = get_number('stop_number')) {
        $message = "Stopped notifications for $stop_num";
        $redis->srem('notify', $stop_num);
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
