# Real short subprocesses exercise argv, output framing and cancellation on the
# test host. This is not Windows PowerShell/Win32 process acceptance.
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use Time::HiRes qw(time);
use VisLlama::Command ();
use VisLlama::Util ();
use VisLlama::Performance ();
my @args=('C:\\Program Files\\models\\x.gguf','$(must-not-run)','`literal`','a b','quoted"value');
my $output=VisLlama::Util::capture_command($^X,'-e','print join(chr(31),@ARGV)',@args);
is($output,join(chr(31),@args),'Arguments reach the child verbatim without a shell');
is(VisLlama::Util::capture_command_stdout($^X,'-e','print qq(stdout);warn qq(stderr)'), 'stdout','Structured stdout excludes stderr');
like(VisLlama::Util::capture_command($^X,'-e','print qq(stdout);warn qq(stderr)'),qr/stderr/,'Combined capture retains diagnostics');
VisLlama::Util::capture_command($^X,'-e','exit 7');is($?,7<<8,'Native exit status retained');
{
 local $VisLlama::Command::TIMEOUT=0.15;my $start=time();
 eval {VisLlama::Util::capture_command($^X,'-e','sleep 10')};
 like($@,qr/timed out/,'Hung native probe has a deadline');
 cmp_ok(time()-$start,'<',2,'Deadline returns control promptly');
}
{
 local $VisLlama::Command::LIMIT=1024;
 eval {VisLlama::Util::capture_command($^X,'-e','print "x" x 100000')};
 like($@,qr/output limit/,'Oversized native output fails instead of silently truncating');
}
{
 my $pumped=0;
 local $VisLlama::Lifecycle::PUMP=sub {$pumped++;VisLlama::Lifecycle::rotate()};
 eval {VisLlama::Util::capture_command($^X,'-e','sleep 10')};
 like($@,qr/Operation cancelled/,'Runtime change cancels an outstanding probe');
 is($pumped,1,'Probe gives the control loop a servicing opportunity');
}
cmp_ok(VisLlama::Performance::payload()->{native_probe}{count},'>=',7,'Probe timings recorded without arguments');
done_testing();
