requires 'perl', '5.008001';

requires 'Cookie::Baker';
requires 'Data::Section::Simple';
requires 'HTTP::Status';
requires 'JSON::PP';
requires 'Plack';
requires 'Router::Boom::Method';
requires 'parent';

on test => sub {
    requires 'Test::More', '0.98';
};
