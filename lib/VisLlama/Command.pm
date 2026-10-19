package VisLlama::Command;
# GPL-3.0-only. Short native probes use argv, file-backed output and a deadline.
# No shell expansion, blocking pipe reads or unbounded diagnostic output.
use strict;
use warnings;
use IPC::Open3;
use File::Temp qw(tempfile);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time);
use VisLlama::Lifecycle ();
use VisLlama::Performance ();
our $LAST_STDERR="";
our $TIMEOUT=15;
our $LIMIT=4*1024*1024;
my %PENDING;
sub stop_child {
    my ($child)=@_;
    if ($^O eq 'MSWin32') {
        # Keep the opened handle rather than authorize a later kill by PID alone.
        if ($child->{handle}) {my $exit=259;$child->{handle}->Kill(1) if $child->{handle}->GetExitCode($exit) && $exit==259;}
    } else {kill 'KILL',$child->{pid};}
}
sub reap {
    for my $pid (keys %PENDING) {
        my $child=$PENDING{$pid};my $done=waitpid($pid,WNOHANG);
        if ($done==$pid || $done==-1) {unlink $_ for @{$child->{files}};delete $PENDING{$pid};}
        else {stop_child($child);}
    }
}
sub capture {
    my ($stdout_only,@cmd)=@_;$LAST_STDERR="";reap();
    die 'Too many native probes awaiting cleanup' if keys(%PENDING)>=4;
    die 'Invalid native command' unless @cmd && !grep {!defined($_)||ref($_)||/\x00/} @cmd;
    my ($out,$outpath)=tempfile('visllama-probe-XXXXXXXX',TMPDIR=>1,UNLINK=>0);
    my ($err,$errpath)=tempfile('visllama-probe-XXXXXXXX',TMPDIR=>1,UNLINK=>0);
    binmode $out;binmode $err;
    my $started=time();my $expected=VisLlama::Lifecycle::token();my ($pid,$status,$failure);
    my $child={files=>[$outpath,$errpath]};
    eval {
        my $input;
        $pid=IPC::Open3::open3($input,'>&'.fileno($out),$stdout_only?'>&'.fileno($err):'>&'.fileno($out),@cmd);
        $child->{pid}=$pid;close $input;
        if ($^O eq 'MSWin32') {
            require Win32::Process;
            my $handle;Win32::Process::Open($handle,$pid,0) or die 'Cannot obtain native probe ownership';
            $child->{handle}=$handle;
        }
        while (1) {
            die 'Native probe output limit exceeded' if (-s $outpath)+(-s $errpath)>$LIMIT;
            my $done=waitpid($pid,WNOHANG);
            if ($done==$pid) {$status=$?;last;}
            die 'Native probe exited without a wait status' if $done==-1;
            die 'Native probe timed out' if time()-$started >= $TIMEOUT;
            die 'Native probe output limit exceeded' if (-s $outpath)+(-s $errpath)>$LIMIT;
            VisLlama::Lifecycle::checkpoint($expected);
            select(undef,undef,undef,0.03);
        }
        1;
    } or $failure=$@;
    if ($failure && $pid && !defined($status)) {
        stop_child($child);
        my $until=time()+1;
        while(time()<$until) {my $done=waitpid($pid,WNOHANG);if($done==$pid||$done==-1){$status=$?;last;}select(undef,undef,undef,0.02);}
        $PENDING{$pid}=$child unless defined $status;
    }
    seek($out,0,0);my $text='';read($out,$text,$LIMIT);
    seek($err,0,0);read($err,$LAST_STDERR,$LIMIT);
    close $out;close $err;
    unlink $outpath,$errpath unless $pid && exists $PENDING{$pid};
    VisLlama::Performance::record('native_probe',time()-$started);
    die $failure if $failure;
    $?=$status//0;
    return $text;
}
END {reap()}
1;
