package Oilert::Util;
use Dancer ':syntax';
use Dancer::Plugin::Email;
use base 'Exporter';

our @EXPORT_OK = qw/email_admin/;

sub email_admin {
    my ($subj, $body) = @_;
    debug "Oilert error: $subj";
    email {
        to => config->{sysadmin_email},
        from => config->{email_from},
        subject => "Oilert error: $subj",
        message => $body || 'Sorry!',
    };
};
