#!perl
use strict;
use warnings;
use App::httpbin;
use Plack::Runner;

my $runner = Plack::Runner->new;
$runner->parse_options(@ARGV);
$runner->run(App::httpbin->new->to_app);

__END__

=head1 SYNOPSIS

  $ httpbin.pl [OPTIONS]

=head1 SEE ALSO

L<plackup>

L<http://httpbin.org/>

=cut
