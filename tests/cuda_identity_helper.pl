# Execute the shipped helper's C# through a native API fixture instead of
# mocking its JSON output. Linux contract test, not Windows hardware validation.
# VISLLAMA_TEST_PWSH runs the full PowerShell helper. Alternatively provide
# VISLLAMA_TEST_MONO and VISLLAMA_TEST_CSC (mcs.exe) to compile and run its exact
# embedded C# with a JSON adapter. gcc builds the temporary native fixture.
# These are optional development tools, never application dependencies.
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Temp qw(tempdir);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);
use JSON::PP qw(decode_json);
my $pwsh=$ENV{VISLLAMA_TEST_PWSH};
my $mono=$ENV{VISLLAMA_TEST_MONO};my $csc=$ENV{VISLLAMA_TEST_CSC};
my $powershell=defined($pwsh) && -x $pwsh;
plan skip_all=>'Linux helper contract test: provide PowerShell or Mono/mcs, plus gcc'
    unless $^O eq 'linux' && ($powershell || (defined($mono) && -x $mono && defined($csc) && -f $csc));
my $dir=tempdir(CLEANUP=>1);
my $fixture="$RealBin/support/cuda_identity_mock.c";
system('gcc','-shared','-fPIC','-Wall','-Wextra','-Werror','-o',"$dir/libkernel32.so",$fixture)==0 or BAIL_OUT('Cannot build native identity fixture');
local $ENV{LD_LIBRARY_PATH}=join(':',$dir,grep {length} ($ENV{LD_LIBRARY_PATH}//''));
my $script=File::Spec->rel2abs("$RealBin/../lib/VisLlama/cuda-devices.ps1");
my @command;
if ($powershell) {
    @command=($pwsh,'-NoLogo','-NoProfile','-NonInteractive','-File',$script,'-Runtime',"$dir/cudart64_12.dll");
} else {
    open my $in,'<',$script or die $!;my $text=do {local $/;<$in>};close $in;
    my ($source)=$text=~/Add-Type -TypeDefinition \@'\r?\n(.*?)\r?\n'\@/s;
    BAIL_OUT('Cannot extract shipped C#') unless defined $source;
    open my $cs,'>',"$dir/probe.cs" or die $!;print {$cs} $source;
    print {$cs} <<'CS';
public static class ProbeRunner {
    static string Json(string value) {
        return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n").Replace("\r", "\\r") + "\"";
    }
    public static int Main(string[] args) {
        try {
            string[] rows=VisLlamaCudaIdentity.Read(args[0]);
            System.Collections.Generic.List<string> items=new System.Collections.Generic.List<string>();
            for(int i=0;i<rows.Length;i++) {
                string[] parts=rows[i].Split('|');
                items.Add("{\"id\":"+Json("CUDA"+i)+",\"bus\":"+Json(parts[0])+",\"uuid\":"+Json(parts[1])+"}");
            }
            Console.WriteLine("["+String.Join(",",items.ToArray())+"]");return 0;
        } catch(Exception ex) {Console.WriteLine("{\"error\":"+Json(ex.Message)+"}");return 1;}
    }
}
CS
    close $cs;
    system($mono,$csc,'-out:'.$dir.'/probe.exe',"$dir/probe.cs")==0 or BAIL_OUT('C# helper compilation failed');
    open my $cfg,'>',"$dir/probe.exe.config" or die $!;
    print {$cfg} '<configuration><dllmap dll="kernel32" target="'.$dir.'/libkernel32.so" /></configuration>';close $cfg;
    @command=($mono,"$dir/probe.exe","$dir/cudart64_12.dll");
    note('Executing actual embedded C# via Mono; PowerShell host behavior is not exercised');
}
sub probe {
    my ($case)=@_;local $ENV{VISLLAMA_CUDA_MOCK_CASE}=$case;
    my $err=gensym;my $pid=open3(undef,my $out,$err,@command);
    my $stdout=do {local $/;<$out>};my $stderr=do {local $/;<$err>};
    waitpid($pid,0);my $exit=$?;
    is($stderr,'',"$case: errors stay in structured private output, not stderr");
    my $data=eval {decode_json($stdout)};
    ok(!$@,"$case: valid JSON") or diag($stdout);
    return ($exit,$data);
}
my ($exit,$data)=probe('normal');
is($exit,0,'Two-device helper succeeds using documented exports only');
is_deeply($data,[
 {id=>'CUDA0',bus=>'0000:0c:00.0',uuid=>'GPU-10111213-1415-1617-1819-1a1b1c1d1e1f'},
 {id=>'CUDA1',bus=>'0000:43:00.0',uuid=>'GPU-80818283-8485-8687-8889-8a8b8c8d8e8f'}
],'Actual string/buffer interop resolves driver UUIDs by bus, not runtime ordinal');
($exit,$data)=probe('single');
is($exit,0,'Single-device helper succeeds');
is_deeply($data,[{id=>'CUDA0',bus=>'0000:0c:00.0',uuid=>'GPU-10111213-1415-1617-1819-1a1b1c1d1e1f'}],
    'Single-device result retains its complete identity');
for my $case (
 ['missing-export',qr/Missing CUDA identity export: cuDeviceGetUuid_v2/],
 ['load-error',qr/Cannot load .*cudart64_12\.dll; Win32 error/],
 ['count-error',qr/cudaGetDeviceCount failed; CUDA error 35/],
 ['init-error',qr/cuInit failed; CUDA error 100/],
 ['bus-error',qr/cudaDeviceGetPCIBusId for CUDA0 failed; CUDA error 101/],
 ['lookup-error',qr/cuDeviceGetByPCIBusId for CUDA0 failed; CUDA error 101/],
 ['uuid-error',qr/cuDeviceGetUuid_v2 for CUDA0 failed; CUDA error 999/],
 ['zero',qr/CUDA device count outside supported range: 0/]
) {
    ($exit,$data)=probe($case->[0]);
    isnt($exit,0,"$case->[0]: helper fails explicitly");
    like(ref($data) eq 'HASH' ? $data->{error}: '',$case->[1],"$case->[0]: private diagnostic identifies failing step");
}
done_testing();
