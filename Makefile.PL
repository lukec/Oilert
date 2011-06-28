use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'Oilert',
    AUTHOR              => q{Luke Closs <cpan@5thplane.com>},
    VERSION_FROM        => 'lib/Oilert.pm',
    ABSTRACT            => 'Oil Tanker Notifier Service',
    ($ExtUtils::MakeMaker::VERSION >= 6.3002
      ? ('LICENSE'=> 'perl')
      : ()),
    PL_FILES            => {},
    PREREQ_PM => {
        'Test::More' => 0,
        'YAML'       => 0,
        'Dancer'     => 1.3060,
        'Plack'      => 0,
        'Math::Polygon' => 0,
        'WWW::Twilio::API' => 0,
        'methods'    => 0,
        'Redis'      => 0,
        'WWW::Shorten::Googl' => 0,
        'Template' => 2.22,
        'Number::Phone' => 0,
        'Web::Scraper' => 0,
        'DateTime' => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'Oilert-*' },
);
