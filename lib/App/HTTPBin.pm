package App::HTTPBin;
use strict;
use warnings;

our $VERSION = '0.01';

use Router::Boom::Method;
use App::HTTPBin::Static;
use Plack::Response;
use Plack::Request;
use JSON::PP ();
use HTTP::Status ();
use Plack::MIME;
use Scalar::Util ();
use Encode ();
use Cookie::Baker ();
use File::Temp ();

my $JSON = JSON::PP->new->utf8(1)->pretty(1)->canonical(1);

sub new {
    my $class = shift;
    bless { router => Router::Boom::Method->new }, $class;
}

sub router { shift->{router} }

sub res {
    my ($self, $code) = @_;
    my $res = Plack::Response->new($code || 200);
    $res->header('Access-Control-Allow-Credentials' => 'true');
    $res->header('Access-Control-Allow-Origin' => '*');
    $res;
}

sub res_common {
    my $self = shift;
    my $code = shift || 200;
    my $message = HTTP::Status::status_message($code) || "";
    my $res = $self->res($code);
    $res->content_type( "text/plain; charset=utf-8" );
    $res->content_length( length $message );
    $res->body($message);
    $res;
}

sub render_json {
    my $self = shift;
    my $data = pop;
    my $code = shift || 200;
    my $res = $self->res($code);
    my $json = $JSON->encode($data);
    $res->content_type("application/json; charset=utf-8");
    $res->content_length(length $json);
    $res->body($json);
    $res;
}
sub render_json_default {
    my ($self, $req) = @_;
    $self->render_json($req->dump);
}

sub render_static {
    my ($self, $name) = @_;
    if (my $static = App::HTTPBin::Static->load($name)) {
        my $type = Plack::MIME->mime_type($name) || "application/octet-stream";
        $type .= "; charset=utf-8" if $type =~ /^text/;
        my $res = $self->res(200);
        $res->content_type($type);
        $res->content_length(length $static);
        $res->body($static);
        return $res;
    } else {
        warn "=> Missing '$name' static file\n";
        $self->res_common(404);
    }
}

{
    package
        App::HTTPBin::Route;
    my @method = qw(get patch post put delete);
    sub new {
        my $class = shift;
        bless +{ map { $_ => [] } @method }, $class;
    }
    for my $method (@method) {
        no strict 'refs';
        *$method = sub {
            my ($self, $path, $code) = @_;
            push @{$self->{$method}}, [$path, $code];
        };
    }
    sub foreach {
        my ($self, $callback) = @_;
        $callback->(["GET", "HEAD"], $_->[0], $_->[1]) for @{ $self->{get} };
        for my $method (grep { $_ ne "get" } @method) {
            $callback->(uc $method, $_->[0], $_->[1]) for @{ $self->{$method} };
        }
    }
}
{
    package
        App::HTTPBin::Request;
    use parent 'Plack::Request';
    sub _fix_case {
        my $str = shift;
        my @part = split /-/, $str;
        join "-", map { ucfirst lc $_ } @part;
    }
    sub header_hash {
        my $self = shift;
        my %headers;
        for my $name ($self->headers->header_field_names) {
            my $value = $self->headers->header($name);
            $headers{ _fix_case $name} = $value;
        }
        \%headers;
    }
    sub dump :method {
        my $self = shift;
        my $url = $self->base;
        $url =~ s{/$}{};
        $url .= $self->path_info;
        {
            args => { %{ $self->query_parameters } },
            origin => $self->address,
            url => $url,
            headers => $self->header_hash,
        };
    }
}

my $route = App::HTTPBin::Route->new;

$route->get("/" => sub {
    my ($self, $req, $capture) = @_;
    $self->render_static("index.html");
});
$route->get("/ip" => sub {
    my ($self, $req, $capture) = @_;
    $self->render_json({origin => $req->address});
});
$route->get("/user-agent" => sub {
    my ($self, $req, $capture) = @_;
    $self->render_json({'user-agent' => $req->user_agent});
});
$route->get("/headers" => sub {
    my ($self, $req, $capture) = @_;
    $self->render_json({headers => $req->header_hash});
});
$route->get("/get" => sub {
    my ($self, $req, $capture) = @_;
    $self->render_json_default($req);
});
$route->post("/post" => sub {
    my ($self, $req, $capture) = @_;
    $self->res_common(404); # TODO
});
$route->patch("/patch" => sub {
    my ($self, $req, $capture) = @_;
    $self->res_common(404); # TODO
});
$route->put("/put" => sub {
    my ($self, $req, $capture) = @_;
    $self->res_common(404); # TODO
});
$route->delete("/delete" => sub {
    my ($self, $req, $capture) = @_;
    $self->res_common(404); # TODO
});
$route->get("/encoding/utf8" => sub {
    my ($self, $req, $capture) = @_;
    my $res = $self->render_static("UTF-8-demo.txt");
    $res->content_type( "text/html; charset=utf-8" );
    $res;
});
$route->get("/gzip" => sub {
    my ($self, $req, $capture) = @_;
    my $json = $JSON->encode($req->dump);
    my $data = "";
    if (eval { require Compress::Zlib; 1 }) {
        $data = Compress::Zlib::memGzip($json);
    } else {
        my ($tempfh, $tempfile) = File::Temp::tempfile(UNLINK => 0);
        my $pid = open my $fh, "|-", "gzip --stdout --no-name > $tempfile";
        print {$fh} $json;
        close $fh;
        $data = do { local $/; <$tempfh> };
        unlink $tempfile;
    }
    my $res = $self->res(200);
    $res->content_type("application/json; charset=utf-8");
    $res->content_length(length $data);
    $res->header('Content-Encoding' => 'gzip');
    $res->body($data);
    $res;
});
$route->get("/deflate" => sub {
    my ($self, $req, $capture) = @_;
    my $json = $JSON->encode($req->dump);
    my $data = "";
    if (eval { require IO::Compress::Deflate; 1 }) {
        IO::Compress::Deflate::deflate(\$json, \$data);
    } else {
        warn "Cannot load IO::Compress::Deflate, $@";
    }
    my $res = $self->res(200);
    $res->content_type("application/json; charset=utf-8");
    $res->content_length(length $data);
    $res->header('Content-Encoding' => 'deflate');
    $res->body($data);
    $res;
});
$route->get("/status/:code" => sub {
    my ($self, $req, $capture) = @_;
    my $code = $capture->{code};
    $self->res_common($code);
});
$route->get("/response-headers" => sub {
    my ($self, $req, $capture) = @_;
    my %params = %{ $req->query_parameters };
    my $res = $self->render_json(\%params);
    $res->header( $_ => $params{$_} ) for keys %params;
    $res;
});
$route->get("/redirect/{n:[0-9]+}" => sub {
    my ($self, $req, $capture) = @_;
    my $n = $capture->{n};
    if ($n > 1) {
        my $res = $self->res(302);
        my $url = $req->base . "redirect/" . ($n - 1);
        $res->header(Location => $url);
        return $res;
    } else {
        my $res = $self->res(302);
        my $url = $req->base . "get";
        $res->header(Location => $url);
        return $res;
    }
});
$route->get("/redirect-to" => sub {
    my ($self, $req, $capture) = @_;
    my $url = $req->query_parameters->{url} || "";
    my $res = $self->res(302);
    $res->header('Location' => Encode::encode_utf8($url));
    $res;
});
$route->get("/relative-redirect/{n:[0-9]+}" => sub {
    my ($self, $req, $capture) = @_;
    $self->res_common(404); # TODO
});
$route->get("/absolute-redirect/{n:[0-9]+}" => sub {
    my ($self, $req, $capture) = @_;
    $self->res_common(404); # TODO
});
$route->get("/cookies" => sub {
    my ($self, $req, $capture) = @_;
    $self->render_json({cookies => $req->cookies});
});
$route->get("/cookies/set" => sub {
    my ($self, $req, $capture) = @_;
    my $res = $self->res(302);
    my %params = %{ $req->query_parameters };
    for my $key (sort keys %params) {
        my $baked = Cookie::Baker::bake_cookie($key, {
            value => $params{$key},
            path => '/',
        });
        $res->headers->push_header('Set-Cookie' => $baked);
    }
    $res->header('Location' => $req->base . 'cookies');
    $res;
});
$route->get("/cookies/delete" => sub {
    my ($self, $req, $capture) = @_;
    my $res = $self->res(302);
    for my $key (keys %{$req->query_parameters}) {
        my $baked = Cookie::Baker::bake_cookie($key, {
            value => '',
            path  => '/',
            expires => 0,
            'max-age' => 0,
        });
        $res->headers->push_header('Set-Cookie' => $baked);
    }
    $res->header('Location' => $req->base . 'cookies');
    $res;
});
$route->get("/basic-auth/:user/:passwd" => sub {
    my ($self, $req, $capture) = @_;
    $self->res_common(404); # TODO
});
$route->get("/hidden-basic-auth/:user/:passwd" => sub {
    my ($self, $req, $capture) = @_;
    $self->res_common(404); # TODO
});
$route->get("/digest-auth/:qop/:user/:passwd" => sub {
    my ($self, $req, $capture) = @_;
    $self->res_common(404); # TODO
});
$route->get("/stream/{n:[0-9]+}" => sub {
    my ($self, $req, $capture) = @_;
    $self->res_common(404); # TODO
});
$route->get("/delay/{n:[0-9]+}" => sub {
    my ($self, $req, $capture) = @_;
    my $n = $capture->{n};
    sleep $n;
    $self->render_json({n => $n});
});
$route->get("/drip" => sub {
    my ($self, $req, $capture) = @_;
    $self->res_common(404); # TODO
});
$route->get("/range/{n:[0-9]+}" => sub {
    my ($self, $req, $capture) = @_;
    my $n = $capture->{n};
    $self->res_common(404); # TODO
});
$route->get("/html" => sub {
    my ($self, $req, $capture) = @_;
    $self->render_static("moby.html");
});
$route->get("/robots.txt" => sub {
    my ($self, $req, $capture) = @_;
    $self->render_static("robots.txt");
});
$route->get("/deny" => sub {
    my ($self, $req, $capture) = @_;
    $self->render_static("angry_ascii.txt");
});
$route->get("/cache" => sub {
    my ($self, $req, $capture) = @_;
    if ($req->header('If-Modified-Since') || $req->header('If-None-Match')) {
        return $self->res(304);
    } else {
        return $self->render_json_default($req);
    }
});
$route->get("/cache/{n:[0-9]+}" => sub {
    my ($self, $req, $capture) = @_;
    my $n = $capture->{n};
    my $res = $self->render_json_default($req);
    $res->header('Cache-Control' => "public, max-age=$n");
    $res;
});
$route->get("/bytes/{n:[0-9]+}" => sub {
    my ($self, $req, $capture) = @_;
    my $n = $capture->{n};
    my $x = "x" x $n;
    my $res = $self->res(200);
    $res->content_type('application/octet-stream');
    $res->content_length($n);
    $res->body($x);
    $res;
});
$route->get("/stream-bytes/{n:[0-9]+}" => sub {
    my ($self, $req, $capture) = @_;
    my $n = $capture->{n};
    $self->res_common(404); # TODO
});
$route->get("/links/{n:[0-9]+}" => sub {
    my ($self, $req, $capture) = @_;
    my $n = $capture->{n};
    $self->res_common(404); # TODO
});
$route->get("/image" => sub {
    my ($self, $req, $capture) = @_;
    $self->res_common(404); # TODO
});
$route->get("/image/png" => sub {
    my ($self, $req, $capture) = @_;
    $self->render_static("images/pig_icon.png");
});
$route->get("/image/jpeg" => sub {
    my ($self, $req, $capture) = @_;
    $self->render_static("images/jackal.jpg");
});
$route->get("/image/webp" => sub {
    my ($self, $req, $capture) = @_;
    $self->render_static("images/wolf_1.webp");
});
$route->get("/image/svg" => sub {
    my ($self, $req, $capture) = @_;
    $self->render_static("images/svg_logo.svg");
});
$route->get("/forms/post" => sub {
    my ($self, $req, $capture) = @_;
    $self->res_common(404); # TODO
});
$route->get("/xml" => sub {
    my ($self, $req, $capture) = @_;
    $self->render_static("sample.xml");
});

sub to_app {
    my $self = shift;
    $route->foreach(sub { $self->router->add(@_) });

    sub {
        my $e = shift;

        my ($dest, $captured, $not_allowed)
            = $self->router->match($e->{REQUEST_METHOD}, $e->{PATH_INFO});
        if ($not_allowed) {
            return $self->res_common(405)->finalize;
        } elsif (!$dest) {
            return $self->res_common(404)->finalize;
        }

        my $req = App::HTTPBin::Request->new($e);
        my $res = eval { $dest->($self, $req, $captured) };
        if ($@) {
            warn $@;
            return $self->res_common(500)->finalize;
        }

        if (Scalar::Util::blessed($res) && $res->can("finalize")) {
            return $res->finalize;
        } else {
            warn "$e->{PATH_INFO}'s callback returns an unexpected object";
            return $self->res_common(500)->finalize;
        }
    };
}

1;
__END__

=encoding utf-8

=head1 NAME

App::HTTPBin - perl port of http://httpbin.org/

=head1 SYNOPSIS

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

=head1 DESCRIPTION

L<http://httpbin.org/> is a HTTP request and response service.
It is very useful when you write HTTP clients and test them.

App::HTTPBin is a perl port of it.

=head1 COPYRIGHT AND LICENSE

Copyright 2015 Shoichi Kaji <skaji@cpan.org>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
