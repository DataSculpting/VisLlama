package VisLlama::Telemetry;

# Sample host/GPU telemetry with the existing cache and platform probes.
# Physical GPU indices are not interchangeable with llama.cpp device identifiers.
use strict;
use warnings;
use Encode ();
use JSON::PP qw(decode_json);

use Time::HiRes qw(time);

use VisLlama::Util qw(jtrue jfalse);
use VisLlama::Errors ();
use VisLlama::Platform ();
my $CPU_PREVIOUS;
our $PROC_ROOT="/proc";
my $GPU_CACHE = { at => 0, data => undef };
my $SYSTEM_CACHE = { at => 0, data => undef };

# PowerShell may prepend a CLIXML marker or append progress XML when its
# streams are redirected. Accept the first complete telemetry JSON object.
sub parse_system_telemetry_json {
    my ($raw) = @_;
    return undef unless defined $raw && length $raw;
    if ($raw =~ /\x00/) {
        my $encoding = substr($raw, 0, 2) eq "\xFE\xFF" ? 'UTF-16BE' : 'UTF-16LE';
        $raw = Encode::encode('UTF-8', Encode::decode($encoding, $raw));
    }
    $raw =~ s/^\xEF\xBB\xBF//;
    my $parsed = eval { decode_json($raw) };
    return $parsed if ref($parsed) eq 'HASH' && exists $parsed->{cpu_percent};
    while ($raw =~ /\{\s*"cpu_percent"\s*:/g) {
        my $candidate = substr($raw, $-[0]);
        my ($item) = eval { JSON::PP->new->decode_prefix($candidate) };
        return $item if ref($item) eq 'HASH' && exists $item->{memory_total_kib};
    }
    return undef;
}

# -----------------------------------------------------------------------------
# Sample Windows host CPU and physical memory without requiring Perl modules.
# Windows CIM reports an approximate per-processor load, averaged here. Encode
# PowerShell as UTF-16LE to keep the command safe through the Windows shell.
# -----------------------------------------------------------------------------
sub collect_system_stats {
    my $now = time();
    return $SYSTEM_CACHE->{data}
        if $SYSTEM_CACHE->{data} && ($now - $SYSTEM_CACHE->{at}) < ($SYSTEM_CACHE->{data}{available} ? 6 : 15);
    my $data = { available => jfalse, sampled_at => scalar localtime, cpu_percent => undef,
                 memory_total_mib => undef, memory_used_mib => undef };
    if ($^O eq 'MSWin32') {
        require MIME::Base64;
        my $script = q{$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'; $problems = @(); $os = $null; $cpus = @(); try { $os = Get-CimInstance Win32_OperatingSystem } catch { $problems += "RAM CIM: $($_.Exception.Message)"; try { $os = Get-WmiObject Win32_OperatingSystem } catch { $problems += "RAM WMI: $($_.Exception.Message)" } }; try { $cpus = @(Get-CimInstance Win32_Processor) } catch { $problems += "CPU CIM: $($_.Exception.Message)"; try { $cpus = @(Get-WmiObject Win32_Processor) } catch { $problems += "CPU WMI: $($_.Exception.Message)" } }; $loads = @($cpus | Where-Object { $null -ne $_.LoadPercentage } | ForEach-Object { $_.LoadPercentage }); $cpu = if ($loads.Count) { ($loads | Measure-Object -Average).Average } else { $null }; $memtotal = if ($os) { $os.TotalVisibleMemorySize } else { $null }; $memfree = if ($os) { $os.FreePhysicalMemory } else { $null }; [pscustomobject]@{ cpu_percent = $cpu; memory_total_kib = $memtotal; memory_free_kib = $memfree; error = ($problems -join '; ') } | ConvertTo-Json -Compress};
        my $encoded = MIME::Base64::encode_base64(Encode::encode('UTF-16LE', $script), '');
        my @cmd = ('powershell.exe', '-NoProfile', '-NonInteractive', '-OutputFormat', 'Text', '-EncodedCommand', $encoded);
        my $out = eval { VisLlama::Util::capture_command_stdout(@cmd) } // '';
        my $parsed = parse_system_telemetry_json($out);
        if (!$parsed) {
            my $combined = eval { VisLlama::Util::capture_command(@cmd) } // '';
            $parsed = parse_system_telemetry_json($combined);
            $out = $combined if length $combined;
        }
        if (ref($parsed) eq 'HASH') {
            if (defined($parsed->{cpu_percent}) && $parsed->{cpu_percent} =~ /^\d+(?:\.\d+)?$/) {
                $data->{cpu_percent} = 0 + $parsed->{cpu_percent};
            }
            if (defined($parsed->{memory_total_kib}) && $parsed->{memory_total_kib} > 0) {
                my $total = 0 + $parsed->{memory_total_kib};
                my $free = 0 + ($parsed->{memory_free_kib} // 0);
                $free = 0 if $free < 0;
                $free = $total if $free > $total;
                $data->{memory_total_mib} = $total / 1024;
                $data->{memory_used_mib} = ($total - $free) / 1024;
            }
            $data->{available} = jtrue if defined($data->{cpu_percent}) || defined($data->{memory_total_mib});
            my @missing;
            push @missing, 'Windows did not return CPU load' unless defined $data->{cpu_percent};
            push @missing, 'Windows did not return physical RAM' unless defined $data->{memory_total_mib};
            $data->{error} = substr(join('; ', grep { defined($_) && length($_) } ($parsed->{error}, @missing)), 0, 260) if @missing;
        } else {
            $out =~ s/[\r\n\t]+/ /g;
            $out =~ s/\s+/ /g;
            $data->{error} = length($out) ? substr($out, 0, 260) : 'PowerShell returned no system data';
        }
    } elsif ($^O eq 'linux') {
        my $linux=eval { linux_system_stats() };
        if ($linux) {%$data=(%$data,%$linux);}
        else {$data->{error}=$@ || 'Linux system telemetry unavailable';}
    } else {
        $data->{error} = 'System telemetry is unavailable on this operating system';
    }
    $data->{error}=VisLlama::Errors::public_text($data->{error},'telemetry_error') if $data->{error};
    $SYSTEM_CACHE = { at => $now, data => $data };
    return $data;
}

# Linux CPU uses successive aggregate samples. guest counters are already in
# user/nice; MemAvailable includes reclaimable cache. First CPU load is unknown.
sub linux_system_stats {
    open my $fh,'<:raw',"$PROC_ROOT/stat" or die "Cannot read Linux CPU counters: $!";
    my $line=<$fh>;close $fh;
    die 'Invalid Linux CPU counters' unless $line =~ /^cpu\s+((?:\d+\s*){4,})$/;
    my @cpu=split /\s+/,$1;my $total=0;$total+=$cpu[$_]//0 for 0..7;
    my $idle=($cpu[3]//0)+($cpu[4]//0);my $percent;
    if ($CPU_PREVIOUS) {
        my $dt=$total-$CPU_PREVIOUS->[0];my $di=$idle-$CPU_PREVIOUS->[1];
        $percent=100*($dt-$di)/$dt if $dt>0 && $di>=0 && $di<=$dt;
    }
    $CPU_PREVIOUS=[$total,$idle];
    open $fh,'<:raw',"$PROC_ROOT/meminfo" or die "Cannot read Linux RAM counters: $!";
    my %memory;while (<$fh>) {$memory{$1}=0+$2 if /^(\w+):\s+(\d+)\s+kB/;}close $fh;
    my $total_mem=$memory{MemTotal};my $available=$memory{MemAvailable};
    die 'Linux RAM counters unavailable' unless $total_mem && defined($available);
    $available=$total_mem if $available>$total_mem;
    return {available=>jtrue,cpu_percent=>$percent,memory_total_mib=>$total_mem/1024,memory_used_mib=>($total_mem-$available)/1024};
}

# -----------------------------------------------------------------------------
# Collect NVIDIA VRAM/utilization/temperature/power telemetry using nvidia-smi.
# -----------------------------------------------------------------------------
sub collect_nvidia_gpu_stats {
    # NVIDIA implementation. AMD and Intel placeholders intentionally follow below.
    # We report nvidia-smi's physical GPU index and UUID rather than pretending it
    # is identical to llama.cpp's CUDA device numbering.
    my $now = time();
    if ($GPU_CACHE->{data} && ($now - ($GPU_CACHE->{at} || 0)) < 1.2) {
        return $GPU_CACHE->{data};
    }
    my @cmd = (VisLlama::Platform::nvidia_smi(),
        '--query-gpu=index,uuid,name,memory.used,memory.total,temperature.gpu,fan.speed,utilization.gpu,power.draw,power.limit',
        '--format=csv,noheader,nounits');
    my $out = eval { VisLlama::Util::capture_command(@cmd) } // '';
    my @gpus;
    for my $line (split /\r?\n/, $out) {
        next unless $line =~ /^\s*\d+\s*,/;
        my @f = split /\s*,\s*/, $line, 10;
        next unless @f >= 10;
        my ($index,$uuid,$name,$mem_used,$mem_total,$temp,$fan,$util,$power,$power_limit)=@f;
        my $num = sub {
            my ($v) = @_;
            return undef unless defined $v;
            $v =~ s/^\s+|\s+$//g;
            return undef if $v eq '' || $v =~ /N\/A|Not Supported|\[N\/A\]/i;
            return 0 + $1 if $v =~ /(-?\d+(?:\.\d+)?)/;
            return undef;
        };
        push @gpus, {
            vendor => 'NVIDIA',
            index => int($index),
            uuid => $uuid,
            name => $name,
            memory_used_mib => $num->($mem_used),
            memory_total_mib => $num->($mem_total),
            temperature_c => $num->($temp),
            fan_percent => $num->($fan),
            utilization_percent => $num->($util),
            power_w => $num->($power),
            power_limit_w => $num->($power_limit),
        };
    }
    my $data = { vendor => 'NVIDIA', available => @gpus ? jtrue : jfalse, gpus => \@gpus, sampled_at => scalar localtime };
    $GPU_CACHE = { at => $now, data => $data };
    return $data;
}

# -----------------------------------------------------------------------------
# Optional AMD telemetry. Discovery runs between requests; reads never probe.
# -----------------------------------------------------------------------------
sub collect_amd_gpu_stats {
    require VisLlama::GPUProviders;
    return VisLlama::GPUProviders::snapshot('AMD');
}

# -----------------------------------------------------------------------------
# Optional Intel telemetry through the same read-only capability registry.
# -----------------------------------------------------------------------------
sub collect_intel_gpu_stats {
    require VisLlama::GPUProviders;
    return VisLlama::GPUProviders::snapshot('Intel');
}

1;
