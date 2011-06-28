package Oilert::Notifier;
use 5.14.0;
use methods;
use Moose;
use WWW::Twilio::API;
use YAML qw/LoadFile/;

has 'config' => (is => 'ro', isa => 'HashRef', lazy_build => 1);
has 'twilio' => (is => 'ro', isa => 'WWW::Twilio::API', lazy_build => 1);

method notify {
    my $ship = shift;

    my $to = '604-807-3906';
    warn "Notifying $to about $ship->{name}\n";
    my $resp = $self->twilio->POST(
        'SMS/Messages',
        From => $self->config->{sms_number},
        To => $to,
        Body => "$ship->{name} is in the Burrard Inlet",
    );
    say "$resp->{content}";
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
