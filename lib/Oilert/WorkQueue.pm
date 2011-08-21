package Oilert::WorkQueue;
use 5.12.0;
use Dancer ':syntax';
use Moose;
use Oilert::Redis;
use JSON qw/encode_json decode_json/;
use Oilert::Util qw/email_admin/;
use Try::Tiny;
use methods;

with 'Oilert::Base';

method add {
    my $job = shift;
    $self->redis->rpush('work_queue', encode_json($job));
}

method run_jobs {
    print 'J';
    while(my $job_json = $self->redis->lpop('work_queue')) {
        try {
            my $job = decode_json $job_json;
            my $class = "Oilert::WorkQueue::$job->{type}";
            $class->new($job)->run;
        }
        catch {
            email_admin(
                "Failed to run a job: $_",
                "Error: $_\n\n$job_json",
            );
        };
    }
}

package Oilert::WorkQueue::SendSMS;
use Moose;
use URI::Encode qw/uri_encode/;
use AnyEvent::HTTP qw/http_request/;
use Oilert::Util qw/email_admin/;
use Data::Dumper;
use methods;

with 'Oilert::Base';

has 'to'   => (is => 'ro', isa => 'Str', required => 1);
has 'body' => (is => 'ro', isa => 'Str', required => 1);

method run {
    my $token = $self->config->{tropo_app_token}
        or die "Can't send text - tropo_app_token is not defined!";
    my $uri = "http://api.tropo.com/1.0/sessions?action=create&token=$token"
        . '&numberToDial=' . $self->to . '&msg=' . uri_encode($self->body, 1);
    http_request GET => $uri, sub {
        my ($body, $headers) = @_;
        if ($headers->{Status} != 200) {
            email_admin("Failed to send SMS to " . $self->to,
                "Couldn't send a SMS, here is the HTTP response and body for the GET request to $uri\n\n"
                . $self->body . "\n\n"
                . Dumper($headers));
        }
        print " (SMS to " . $self->to . " OK) ";
    };
}



