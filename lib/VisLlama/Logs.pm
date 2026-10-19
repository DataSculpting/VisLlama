package VisLlama::Logs;

# Decode launcher logs and expose bounded tails. Clearing the UI advances
# view offsets while retaining the actual log files for later diagnostics.
use strict;
use warnings;
use Encode qw(decode FB_DEFAULT);

use VisLlama::Context qw($STATE);
use VisLlama::Util qw(jtrue);

# -----------------------------------------------------------------------------
# Decode PowerShell/llama-server logs, including UTF-16LE redirected output.
# -----------------------------------------------------------------------------
sub decode_log_bytes {
    my ($bytes) = @_;
    return '' unless defined $bytes && length $bytes;

    # Windows PowerShell 5.1 redirection commonly writes UTF-16LE. Tail reads
    # may begin after the BOM, so also detect alternating NUL-byte patterns.
    if (substr($bytes, 0, 2) eq "\xFF\xFE") {
        $bytes = substr($bytes, 2);
        chop $bytes if length($bytes) % 2;
        return decode('UTF-16LE', $bytes, FB_DEFAULT);
    }
    if (substr($bytes, 0, 2) eq "\xFE\xFF") {
        $bytes = substr($bytes, 2);
        chop $bytes if length($bytes) % 2;
        return decode('UTF-16BE', $bytes, FB_DEFAULT);
    }

    my $sample = substr($bytes, 0, length($bytes) > 4096 ? 4096 : length($bytes));
    my ($nul_even, $nul_odd) = (0, 0);
    for (my $i = 0; $i < length($sample); $i++) {
        next unless substr($sample, $i, 1) eq "\x00";
        $i % 2 ? $nul_odd++ : $nul_even++;
    }
    my $pairs = int(length($sample) / 2) || 1;
    if ($nul_odd > $pairs / 4 && $nul_odd > ($nul_even * 3 + 2)) {
        chop $bytes if length($bytes) % 2;
        return decode('UTF-16LE', $bytes, FB_DEFAULT);
    }
    if ($nul_even > $pairs / 4 && $nul_even > ($nul_odd * 3 + 2)) {
        # The tail seek landed on the second byte of a UTF-16LE code unit.
        $bytes = substr($bytes, 1);
        chop $bytes if length($bytes) % 2;
        return decode('UTF-16LE', $bytes, FB_DEFAULT);
    }

    return decode('UTF-8', $bytes, FB_DEFAULT);
}

# -----------------------------------------------------------------------------
# Extract likely failure lines from the combined server logs.
# -----------------------------------------------------------------------------
sub extract_error_from_log {
    my ($file) = @_;
    return undef unless $file && -f $file;
    open my $fh, '<:raw', $file or return undef;
    my $size = -s $fh;
    my $max = 160000;
    seek($fh, $size > $max ? $size - $max : 0, 0);
    local $/;
    my $text = <$fh> // '';
    close $fh;
    $text = decode_log_bytes($text);
    $text =~ s/^.*?\n// if $size > $max;
    my @lines = grep { /\S/ } split /\r?\n/, $text;
    my @err = grep { /(?:fatal|error|failed|failure|exception|assert|abort|out of memory|cannot|invalid|cuda.*(?:fail|error)|cublas.*(?:fail|error)|ggml.*(?:fail|error))/i } @lines;
    my @pick = @err ? @err[-(@err > 14 ? 14 : scalar @err) .. -1] : @lines[-(@lines > 24 ? 24 : scalar @lines) .. -1];
    return undef unless @pick;
    my $out = join("\n", @pick);
    $out = substr($out, -12000) if length($out) > 12000;
    return $out;
}

# -----------------------------------------------------------------------------
# Translate Windows/NTSTATUS process exit codes into readable diagnostics.
# -----------------------------------------------------------------------------
sub decode_native_exit {
    my ($code,$proc)=@_;
    if ($proc && $proc->isa('VisLlama::Platform::Linux')) {
        return (undef,$proc->{signal} ? 'SIGNAL_'.$proc->{signal} : 'EXIT_'.$code);
    }
    return decode_windows_exit($code);
}

sub decode_windows_exit {
    my ($code) = @_;
    return (undef, undef) unless defined $code;
    my $u = $code < 0 ? $code + 4294967296 : $code;
    $u %= 4294967296;
    my $hex = sprintf('0x%08X', $u);
    my %known = (
        0xC0000005 => 'STATUS_ACCESS_VIOLATION',
        0xC000001D => 'STATUS_ILLEGAL_INSTRUCTION',
        0xC0000094 => 'STATUS_INTEGER_DIVIDE_BY_ZERO',
        0xC0000096 => 'STATUS_PRIVILEGED_INSTRUCTION',
        0xC00000FD => 'STATUS_STACK_OVERFLOW',
        0xC0000135 => 'STATUS_DLL_NOT_FOUND',
        0xC0000139 => 'STATUS_ENTRYPOINT_NOT_FOUND',
        0xC0000142 => 'STATUS_DLL_INIT_FAILED',
        0xC0000409 => 'STATUS_STACK_BUFFER_OVERRUN',
        0xC0000374 => 'STATUS_HEAP_CORRUPTION',
    );
    return ($hex, $known{$u});
}

# -----------------------------------------------------------------------------
# Read and decode the tail of one log file.
# -----------------------------------------------------------------------------
sub read_log_tail_file {
    my ($file,$max) = @_;
    return '' unless $file && -f $file;
    open my $fh, '<:raw', $file or return '';
    my $size = -s $fh;
    my $start = $size > $max ? $size - $max : 0;
    seek($fh,$start,0);
    local $/; my $s=<$fh>//''; close $fh;
    $s = decode_log_bytes($s);
    $s =~ s/^.*?\n// if $start > 0;
    return $s;
}

# -----------------------------------------------------------------------------
# Combine relevant engine/proxy log tails for the diagnostics UI.
# -----------------------------------------------------------------------------
sub tail_log {
    my ($max) = @_;
    $max ||= 30000;
    if (($STATE->{mode}//'') eq 'router') {
        my @chunks;
        my @engines = sort { ($a->{build}//'') cmp ($b->{build}//'') } values %{$STATE->{router_engines} || {}};
        my $per = @engines ? int($max / @engines) : $max;
        $per = 6000 if $per < 6000;
        for my $eng (@engines) {
            my $txt = read_log_tail_file($eng->{log_file}, $per);
            if (($eng->{log_clear_offset}//0) > 0 && $eng->{log_file} && -f $eng->{log_file}) {
                open my $cfh, '<:raw', $eng->{log_file};
                my $size = -s $cfh;
                my $off = $eng->{log_clear_offset};
                if ($size >= $off) { seek($cfh,$off,0); local $/; my $raw=<$cfh>//''; $txt=decode_log_bytes($raw); }
                close $cfh;
            }
            push @chunks, "===== " . ($eng->{build}//'router') . ($eng->{isolation} ? ' ['.join(',',@{$eng->{isolation}{devices}}).']' : '') . " =====\n" . $txt if length $txt;
        }
        return join("\n", @chunks);
    }
    my $file = $STATE->{log_file};
    return '' unless $file && -f $file;
    open my $fh, '<:raw', $file or return '';
    my $size = -s $fh;
    my $clear = $STATE->{log_clear_offset} // 0;
    $clear = 0 if $clear < 0 || $clear > $size;
    my $start = $size > $max ? $size - $max : 0;
    $start = $clear if $clear > $start;
    seek($fh, $start, 0);
    local $/;
    my $s = <$fh> // '';
    close $fh;
    $s = decode_log_bytes($s);
    $s =~ s/^.*?\n// if $start > $clear;
    return $s;
}

# -----------------------------------------------------------------------------
# Advance the visible log offset without truncating an active log file.
# -----------------------------------------------------------------------------
sub clear_log_view {
    if (($STATE->{mode}//'') eq 'router') {
        for my $eng (values %{$STATE->{router_engines} || {}}) {
            my $file=$eng->{log_file};
            my $size=($file && -f $file) ? -s $file : 0;
            $eng->{log_clear_offset}=defined($size)?$size:0;
        }
    } else {
        my $file = $STATE->{log_file};
        if ($file && -f $file) {
            my $size = -s $file;
            $STATE->{log_clear_offset} = defined($size) ? $size : 0;
        } else {
            $STATE->{log_clear_offset} = 0;
        }
    }
    return { ok=>jtrue, message=>'Log view cleared. The underlying log file was preserved for diagnostics.' };
}

1;
