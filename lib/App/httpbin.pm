package App::httpbin;
use strict;
use warnings;

our $VERSION = '0.01';

use App::httpbin::Static;
use Cookie::Baker ();
use Encode ();
use File::Temp ();
use HTTP::Status ();
use JSON::PP ();
use MIME::Base64 ();
use Plack::MIME;
use Plack::Middleware::Auth::Basic;
use Plack::Middleware::Auth::Digest;
use Plack::Request;
use Plack::Response;
use Router::Boom::Method;
use Scalar::Util ();

BEGIN { Plack::MIME->add_type('.webp' => 'image/webp') }

my $JSON = JSON::PP->new->utf8(1)->pretty(1)->canonical(1);

sub new {
    my $class = shift;
    bless { router => Router::Boom::Method->new }, $class;
}

sub router { shift->{router} }

{
    package
        App::httpbin::Controller;
    sub new {
        my ($class, $req) = @_;
        bless { req => $req }, $class;
    }
    sub req { shift->{req} }

    sub res {
        my ($self, $code) = @_;
        my $res = Plack::Response->new($code || 200);
        $res->header('Access-Control-Allow-Credentials' => 'true');
        $res->header('Access-Control-Allow-Origin' => '*');
        $res;
    }
    sub res_todo {
        my $res = shift->res(200);
        my $body = "TODO";
        $res->body($body);
        $res->content_length(length $body);
        $res->content_type("text/plain; charset=utf-8" );
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

    sub res_redirect {
        my ($self, $path) = @_;
        ($path ||= "") =~ s{^/}{};
        my $res = $self->res(302);
        $res->content_length(0);
        $res->header(Location => $self->req->base . $path);
        $res;
    }

    sub render_json {
        my ($self, $data) = @_;
        my $res = $self->res(200);
        my $json = $JSON->encode($data);
        $res->content_type("application/json; charset=utf-8");
        $res->content_length(length $json);
        $res->body($json);
        $res;
    }

    sub render_static {
        my ($self, $name) = @_;
        if (my $static = App::httpbin::Static->load($name)) {
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
}

{
    package
        App::httpbin::Route;
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
        App::httpbin::Request;
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
        my ($self, @key) = @_;
        my $url = $self->base;
        $url =~ s{/$}{};
        $url .= $self->path_info;
        {
            args => { %{ $self->query_parameters } },
            origin => $self->address,
            url => $url,
            headers => $self->header_hash,
            forms => { %{ $self->body_parameters } },
        };
    }
}

my $route = App::httpbin::Route->new;

$route->get("/" => sub {
    my ($self, $capture) = @_;
    $self->render_static("index.html");
});
$route->get("/ip" => sub {
    my ($self, $capture) = @_;
    $self->render_json({origin => $self->req->address});
});
$route->get("/user-agent" => sub {
    my ($self, $capture) = @_;
    $self->render_json({'user-agent' => $self->req->user_agent});
});
$route->get("/headers" => sub {
    my ($self, $capture) = @_;
    $self->render_json({headers => $self->req->header_hash});
});
$route->get("/get" => sub {
    my ($self, $capture) = @_;
    $self->render_json($self->req->dump);
});
$route->post("/post" => sub {
    my ($self, $capture) = @_;
    $self->render_json($self->req->dump);
});
$route->patch("/patch" => sub {
    my ($self, $capture) = @_;
    $self->render_json($self->req->dump);
});
$route->put("/put" => sub {
    my ($self, $capture) = @_;
    $self->render_json($self->req->dump);
});
$route->delete("/delete" => sub {
    my ($self, $capture) = @_;
    $self->render_json($self->req->dump);
});
$route->get("/encoding/utf8" => sub {
    my ($self, $capture) = @_;
    my $res = $self->render_static("UTF-8-demo.txt");
    $res->content_type( "text/html; charset=utf-8" );
    $res;
});
$route->get("/gzip" => sub {
    my ($self, $capture) = @_;
    my $json = $JSON->encode($self->req->dump);
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
    my ($self, $capture) = @_;
    my $json = $JSON->encode($self->req->dump);
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
    my ($self, $capture) = @_;
    my $code = $capture->{code};
    $self->res_common($code);
});
$route->get("/response-headers" => sub {
    my ($self, $capture) = @_;
    my %params = %{ $self->req->query_parameters };
    my $res = $self->render_json(\%params);
    $res->header( $_ => $params{$_} ) for keys %params;
    $res;
});
$route->get("/redirect/{n:[0-9]+}" => sub {
    my ($self, $capture) = @_;
    my $n = $capture->{n};
    if ($n > 1) {
        return $self->res_redirect("/redirect/" . ($n - 1));
    } else {
        return $self->res_redirect("/get");
    }
});
$route->get("/redirect-to" => sub {
    my ($self, $capture) = @_;
    my $url = $self->req->query_parameters->{url} || "";
    my $res = $self->res(302);
    $res->header(Location => $url);
    $res;
});
$route->get("/relative-redirect/{n:[0-9]+}" => sub {
    my ($self, $capture) = @_;
    $self->res_todo; # TODO
});
$route->get("/absolute-redirect/{n:[0-9]+}" => sub {
    my ($self, $capture) = @_;
    $self->res_todo; # TODO
});
$route->get("/cookies" => sub {
    my ($self, $capture) = @_;
    $self->render_json({cookies => $self->req->cookies});
});
$route->get("/cookies/set" => sub {
    my ($self, $capture) = @_;
    my $res = $self->res_redirect("/cookies");
    my %params = %{ $self->req->query_parameters };
    for my $key (sort keys %params) {
        my $baked = Cookie::Baker::bake_cookie($key, {
            value => $params{$key},
            path => '/',
        });
        $res->headers->push_header('Set-Cookie' => $baked);
    }
    $res;
});
$route->get("/cookies/delete" => sub {
    my ($self, $capture) = @_;
    my $res = $self->res_redirect("/cookies");
    for my $key (keys %{$self->req->query_parameters}) {
        my $baked = Cookie::Baker::bake_cookie($key, {
            value => '',
            path  => '/',
            expires => 0,
            'max-age' => 0,
        });
        $baked .= "; max-age=0"; # FIXME
        $res->headers->push_header('Set-Cookie' => $baked);
    }
    $res;
});
$route->get("/basic-auth/:user/:passwd" => sub {
    my ($self, $capture) = @_;
    my $basic = Plack::Middleware::Auth::Basic->new(
        authenticator => sub { $capture->{user} eq $_[0] && $capture->{passwd} eq $_[1] },
        app => sub { $self->render_json($self->req->dump) },
    );
    $basic->call($self->req->env);
});
$route->get("/hidden-basic-auth/:user/:passwd" => sub {
    my ($self, $capture) = @_;
    my $auth = $self->req->env->{HTTP_AUTHORIZATION};
    return $self->res_common(404) unless !$auth || $auth !~ /^Basic (.*)$/i;
    my ($user, $pass) = split /:/, (MIME::Base64::decode($1) || ":"), 2;
    $pass = '' unless defined $pass;
    if ($user eq $capture->{user} && $pass eq $capture->{passwd}) {
        return $self->render_json($self->req->dump);
    } else {
        return $self->res_common(404);
    }
});
$route->get("/digest-auth/:qop/:user/:passwd" => sub {
    my ($self, $capture) = @_;
    if ($capture->{qop} ne "auth" && $capture->{qop} ne "auth-int") {
        return $self->res_common(404);
    }
    my $digest = Plack::Middleware::Auth::Digest->new(
        authenticator => sub { $_[0] eq $capture->{user} ? $capture->{passwd} : undef },
        secret => 'blahblahblah',
        app => sub { $self->render_json($self->req->dump) },
    );
    $digest->call($self->req->env);
});
$route->get("/stream/{n:[0-9]+}" => sub {
    my ($self, $capture) = @_;
    $self->res_todo; # TODO
});
$route->get("/delay/{n:[0-9]+}" => sub {
    my ($self, $capture) = @_;
    my $n = $capture->{n};
    sleep $n;
    $self->render_json({n => $n});
});
$route->get("/drip" => sub {
    my ($self, $capture) = @_;
    $self->res_todo; # TODO
});
$route->get("/range/{n:[0-9]+}" => sub {
    my ($self, $capture) = @_;
    my $n = $capture->{n};
    $self->res_todo; # TODO
});
$route->get("/html" => sub {
    my ($self, $capture) = @_;
    $self->render_static("moby.html");
});
$route->get("/robots.txt" => sub {
    my ($self, $capture) = @_;
    $self->render_static("robots.txt");
});
$route->get("/deny" => sub {
    my ($self, $capture) = @_;
    $self->render_static("angry_ascii.txt");
});
$route->get("/cache" => sub {
    my ($self, $capture) = @_;
    if ($self->req->header('If-Modified-Since') || $self->req->header('If-None-Match')) {
        return $self->res(304);
    } else {
        return $self->render_json($self->req->dump);
    }
});
$route->get("/cache/{n:[0-9]+}" => sub {
    my ($self, $capture) = @_;
    my $n = $capture->{n};
    my $res = $self->render_json($self->req->dump);
    $res->header('Cache-Control' => "public, max-age=$n");
    $res;
});
$route->get("/bytes/{n:[0-9]+}" => sub {
    my ($self, $capture) = @_;
    my $n = $capture->{n};
    my $x = "x" x $n;
    my $res = $self->res(200);
    $res->content_type('application/octet-stream');
    $res->content_length($n);
    $res->body($x);
    $res;
});
$route->get("/stream-bytes/{n:[0-9]+}" => sub {
    my ($self, $capture) = @_;
    my $n = $capture->{n};
    $self->res_todo; # TODO
});
$route->get("/links/{n:[0-9]+}/{offset:[0-9]+}" => sub {
    my ($self, $capture) = @_;
    my $n = $capture->{n};
    $self->res_todo; # TODO
});
$route->get("/image" => sub {
    my ($self, $capture) = @_;

    local $_ = lc($self->req->header('accept') || "");

    my $static;
    if (!$_) {
        $static = 'images/pig_icon.png';
    } elsif (m{image/webp}) {
        $static = 'images/wolf_1.webp';
    } elsif (m{image/svg\+xml}) {
        $static = 'images/svg_logo.svg';
    } elsif (m{image/jpeg}) {
        $static = 'images/jackal.jpg';
    } elsif (m{image/png} or m{image/\*}) {
        $static = 'images/pig_icon.png';
    }

    if ($static) {
        $self->render_static($static);
    } else {
        $self->res_common(406);
    }
});
$route->get("/image/png" => sub {
    my ($self, $capture) = @_;
    $self->render_static("images/pig_icon.png");
});
$route->get("/image/jpeg" => sub {
    my ($self, $capture) = @_;
    $self->render_static("images/jackal.jpg");
});
$route->get("/image/webp" => sub {
    my ($self, $capture) = @_;
    $self->render_static("images/wolf_1.webp");
});
$route->get("/image/svg" => sub {
    my ($self, $capture) = @_;
    $self->render_static("images/svg_logo.svg");
});
$route->get("/forms/post" => sub {
    my ($self, $capture) = @_;
    $self->render_static("forms-post.html");
});
$route->get("/xml" => sub {
    my ($self, $capture) = @_;
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
            return App::httpbin::Controller->res_common(405)->finalize;
        } elsif (!$dest) {
            return App::httpbin::Controller->res_common(404)->finalize;
        }

        my $c = App::httpbin::Controller->new(App::httpbin::Request->new($e));
        my $res = eval { $dest->($c, $captured) };
        if ($@) {
            warn $@;
            return $c->res_common(500)->finalize;
        }

        if (Scalar::Util::blessed($res) && $res->can("finalize")) {
            return $res->finalize;
        } elsif (ref $res eq "ARRAY" and @$res == 3) {
            return $res;
        } else {
            warn "$e->{PATH_INFO}'s callback returns an unexpected object";
            return $c->res_common(500)->finalize;
        }
    };
}

1;
__END__

=encoding utf-8

=head1 NAME

App::httpbin - perl port of http://httpbin.org/

=head1 SYNOPSIS

  use Test::TCP;
  use Test::More;
  use Plack::Loader;
  use App::httpbin;

  my $server = Test::TCP->new(code => sub {
    my $port = shift;
    my $app = App::httpbin->new->to_app;
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

App::httpbin is a perl port of it.

=head1 COPYRIGHT AND LICENSE

Copyright 2015 Shoichi Kaji <skaji@cpan.org>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
