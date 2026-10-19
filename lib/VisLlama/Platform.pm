package VisLlama::Platform;

# Native operations only. Router policy, catalog order and GPU planning remain
# shared; Windows launchers keep their existing PowerShell argument encoding.
use strict;
use warnings;
use File::Spec;
use JSON::PP ();
use VisLlama::Paths ();
use VisLlama::Util ();
sub windows { $^O eq 'MSWin32' }
sub server_name { windows() ? 'llama-server.exe' : 'llama-server' }
sub nvidia_smi { windows() ? 'nvidia-smi.exe' : 'nvidia-smi' }
sub path_key { windows() ? lc($_[0]) : $_[0] }
sub launcher_suffix { windows() ? '.ps1' : '.json' }
sub flags {
    require Win32::Process;
    return Win32::Process::NORMAL_PRIORITY_CLASS() | Win32::Process::CREATE_NEW_PROCESS_GROUP();
}
sub write_spec {
    my ($file,$exe,$args,$cwd,$log,$exit_file,$profile,$extra)=@_;
    my %env=%{$extra||{}};
    $env{CUDA_VISIBLE_DEVICES}=$profile->{visible} if $profile;
    my $docker=$exe =~ m{\Adocker://};
    my $spec={exe=>($docker?$exe:File::Spec->rel2abs($exe)),args=>$args,cwd=>($docker?VisLlama::Paths::app_base_dir():File::Spec->rel2abs($cwd)),log=>$log,exit_file=>$exit_file,env=>\%env};
    $spec->{docker_image_id}=$profile->{image_id} if $docker && $profile && $profile->{image_id};
    open my $fh,'>:raw',$file or die "Cannot write launcher: $!";
    print {$fh} JSON::PP->new->ascii->canonical->encode($spec) or die "Cannot write launcher: $!";
    close $fh or die "Cannot close launcher: $!";
    if ($profile) {
        open my $out,'>>:encoding(UTF-8)',$log or die "Cannot write launch log: $!";
        print {$out} 'VisLlama GPU mapping: '.(@{$profile->{devices}} ? join('; ',map {$profile->{devices}[$_].' -> CUDA'.$_.' ('.$profile->{uuids}[$_].')'} 0..$#{$profile->{devices}}) : 'CPU only; no CUDA devices visible')."\n";
        close $out;
    }
}
sub launch {
    my ($launcher,$cwd)=@_;
    if (windows()) {
        require Win32;require Win32::Process;Win32::Process->import();
        my $powershell=File::Spec->catfile($ENV{SystemRoot}||'C:\\Windows','System32','WindowsPowerShell','v1.0','powershell.exe');
        $powershell='powershell.exe' unless -f $powershell;
        my $cmd='powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '.VisLlama::Util::shell_quote_win($launcher);
        my $proc;
        Win32::Process::Create($proc,$powershell,$cmd,0,flags(),$cwd)
            or die 'Failed to start managed process: '.Win32::FormatMessage(Win32::GetLastError());
        return $proc;
    }
    die 'Unsupported operating system' unless $^O eq 'linux';
    require VisLlama::Platform::Linux;
    open my $fh,'<:raw',$launcher or die "Cannot read launcher: $!";
    my $text=do {local $/;<$fh>};close $fh;
    my $spec=JSON::PP->new->decode($text);
    if ($spec->{exe} =~ m{\Adocker://}) {require VisLlama::Docker;return VisLlama::Docker::launch($spec);}
    return VisLlama::Platform::Linux->launch($spec);
}
1;
