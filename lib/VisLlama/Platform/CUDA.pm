package VisLlama::Platform::CUDA;

# Inspect the selected executable's actual CUDA linkage, never a global runtime
# guess. Native fitting remains available when explicit isolation is unsupported.
use strict;
use warnings;
use File::Spec;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Config ();
use JSON::PP ();
use VisLlama::Command ();
use VisLlama::Paths ();
use VisLlama::Util ();
sub helper {
 my $source=File::Spec->catfile(dirname(__FILE__),'cuda-devices.c');
 open my $fh,'<:raw',$source or die "Cannot read CUDA helper source: $!";
 my $bytes=do {local $/;<$fh>};close $fh;
 my $dir=File::Spec->catdir(VisLlama::Paths::app_base_dir(),'logs');mkdir $dir unless -d $dir;
 my $key=substr(sha256_hex($bytes.$Config::Config{archname}),0,20);
 my $exe=File::Spec->rel2abs(File::Spec->catfile($dir,"cuda-identity-$key"));
 return $exe if -f $exe && -x $exe;
 my $temporary=$exe.'.'.$$.'.tmp';
 my $out=eval {VisLlama::Util::capture_command('cc','-std=c99','-O2','-Wall','-Wextra',$source,'-ldl','-o',$temporary)};
 my $error=$@;my $exit=$?;
 if ($error || $exit || !-x $temporary) {unlink $temporary;die 'GPU isolation could not be verified: Linux identity helper compilation failed (install a C compiler): '.($error||$out||$exit);}
 rename($temporary,$exe) or do {unlink $temporary;die "Cannot publish CUDA identity helper: $!";};
 return $exe;
}
# GNU loader diagnostics reveal the libraries actually initialized by the
# selected executable, including backend dlopen/RUNPATH resolution. They remain
# private. Never infer its runtime from a similarly named adjacent library.
sub linkage {
 my ($exe)=@_;my $trace;
 {local $ENV{LD_DEBUG}='libs';local $ENV{LD_DEBUG_OUTPUT};delete $ENV{LD_DEBUG_OUTPUT};
  $trace=VisLlama::Util::capture_command($exe,'--list-devices');}
 my $exit=$?;
 die "GPU isolation could not be verified: Selected Linux build device/linkage probe failed ($exit): $trace" if $exit;
 my (%backends,%runtimes);
 for my $line (split /\n/,$trace) {
  next unless $line =~ /calling init:\s+(.+?)\s*$/;
  my $path=abs_path($1);next unless defined $path;
  $backends{$path}=1 if $path =~ m{/(?:libggml-cuda\.so)(?:\.[0-9.]+)?$};
  $runtimes{$path}=1 if $path =~ m{/libcudart\.so(?:\.[0-9.]+)?$};
 }
 die 'GPU isolation could not be verified: Cannot verify Linux CUDA linkage (GNU loader tracing required; hidden static runtime unsupported)' unless keys(%backends)==1 || (!keys(%backends) && keys(%runtimes)==1);
 die 'GPU isolation could not be verified: Ambiguous loaded CUDA runtimes' if keys(%runtimes)>1;
 my $backend=keys(%backends) ? (keys %backends)[0] : (keys %runtimes)[0];
 # Exported static runtime symbols may reside in the backend itself. Hidden
 # static symbols are rejected by the helper rather than replaced with a guess.
 my $runtime=keys(%runtimes) ? (keys %runtimes)[0] : $backend;
 return ($backend,$runtime,$trace);
}
sub probe {
 my ($exe)=@_;my ($backend,$runtime)=linkage($exe);my $helper=helper();
 my $json=VisLlama::Util::capture_command_stdout($helper,$backend,$runtime);my $exit=$?;
 if ($exit) {$json=JSON::PP->new->ascii->encode({error=>$VisLlama::Command::LAST_STDERR || $json || 'Native CUDA helper failed'});}
 $?=$exit;return $json;
}
1;
