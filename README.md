[![Build Status](https://travis-ci.org/shoichikaji/perl-httpbin.svg?branch=master)](https://travis-ci.org/shoichikaji/perl-httpbin)

# NAME

App::HTTPBin - perl port of http://httpbin.org/

# SYNOPSIS

    use Test::TCP;
    use Test::More;
    use Plack::Loader;
    use App::HTTPBin;

    my $server = Test::TCP->new(code => sub {
      my $port = shift;
      my $app = App::HTTPBin->new->to_app;
      Plack::Loader->auto(port => $port)->run($app);
    });

    my $url = "http://localhost:" . $server->port;

    # client test here !
    use HTTP::Tiny;
    my $http = HTTP::Tiny->new;
    my $res = $http->get("$url/status/503");
    is $res->{status}, 503;

    done_testing;

# DESCRIPTION

[http://httpbin.org/](http://httpbin.org/) is a HTTP request and response service.
It is very useful when you write HTTP clients and test them.

App::HTTPBin is a perl port of it.

# COPYRIGHT AND LICENSE

Copyright 2015 Shoichi Kaji &lt;skaji@cpan.org>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.
