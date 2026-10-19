package VisLlama::GPUParsers;

# Read-only vendor output adapters. CLI indices identify records within a probe,
# not inference devices. No parser here authorizes physical GPU placement.
use strict;
use warnings;
use JSON::PP ();
use Encode qw(decode FB_CROAK);
our @MEASUREMENTS=qw(memory_used_mib memory_total_mib temperature_c fan_percent utilization_percent power_w power_limit_w);

sub text {
    my ($raw)=@_;die 'Missing GPU tool output' unless defined $raw;
    $raw=decode('UTF-8',$raw,FB_CROAK) unless utf8::is_utf8($raw);
    $raw =~ s/^\x{FEFF}//;
    return $raw;
}
sub json {
    my ($raw)=@_;my $data=JSON::PP->new->decode(text($raw));
    die 'GPU tool reported an error' if ref($data) eq 'HASH' && (exists $data->{error} || exists $data->{error_code});
    return $data;
}
# Numeric fields are strict: error strings, booleans and non-finite readings
# remain unknown, never a plausible-looking number extracted from an error.
sub number {
    my ($v)=@_;return undef if !defined($v) || ref($v);
    $v =~ s/^\s+|\s+$//g;
    return undef unless $v =~ /\A-?(?:\d+(?:\.\d*)?|\.\d+)\z/;
    my $n=0+$v;return undef if abs($n)>1e15;return $n;
}
sub quantity {
    my ($v,$unit)=@_;return undef unless ref($v) eq 'HASH' && ($v->{unit}//'') eq $unit;
    return number($v->{value});
}
sub string {
    my ($v)=@_;return undef if !defined($v)||ref($v);
    $v =~ s/^\s+|\s+$//g;
    return undef if $v eq '' || $v =~ /\A(?:N\/A|unknown|not supported|none|null)\z/i || $v =~ /[\x00-\x1f]/;
    return $v;
}
sub bdf {
    my ($v)=@_;$v=string($v);return undef unless defined($v) && $v =~ /\A([0-9a-f]{4,8}):([0-9a-f]{2}):([0-9a-f]{2})\.([0-7])\z/i;
    return undef if hex($3)>31;
    return sprintf('%08x:%02x:%02x.%x',hex($1),hex($2),hex($3),hex($4));
}
sub uuid {
    my ($v)=@_;$v=string($v);return undef unless defined $v;
    return undef unless $v =~ /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i;
    return undef if $v =~ /\A[0-]+\z/;
    return lc $v;
}
sub record {
    my ($vendor,$provider,$index,$name,$id,$bus)=@_;
    return {vendor=>$vendor,provider=>$provider,index=>$index,name=>string($name)//"$vendor GPU",
        uuid=>uuid($id),pci_bus_id=>bdf($bus),map {$_=>undef} @MEASUREMENTS};
}
sub finish {
    my ($r,$schema,$semantics)=@_;
    for my $k (@MEASUREMENTS) {
        my $v=number($r->{$k});
        $v=undef if defined($v) && ($k ne 'temperature_c' && $v<0 || $k =~ /percent$/ && $v>100);
        $r->{$k}=$v;
    }
    # A contradictory pair is not a valid memory-use percentage.
    $r->{memory_used_mib}=undef if defined($r->{memory_used_mib}) && defined($r->{memory_total_mib}) && $r->{memory_used_mib}>$r->{memory_total_mib};
    $r->{schema}=$schema;$r->{semantics}=$semantics;
    $r->{identity_status}=($r->{uuid}||$r->{pci_bus_id})?'identity_candidate':'identity_unverified';
    $r->{explicit_placement_ready}=JSON::PP::false;
    $r->{capabilities}={map {$_=>defined($r->{$_})?'supported':'unavailable'} @MEASUREMENTS};
    return $r;
}
sub amd_rows {
    my ($raw)=@_;my $a=json($raw);die 'Unsupported AMD-SMI JSON schema' unless ref($a) eq 'ARRAY';
    my %seen;
    for my $r (@$a) {
        die 'Unsupported AMD-SMI device record' unless ref($r) eq 'HASH' && defined(number($r->{gpu})) && $r->{gpu} =~ /\A\d+\z/ && !$seen{$r->{gpu}}++;
    }
    return $a;
}
sub amd_inventory {
    my ($raw)=@_;return [map {record('AMD','amd-smi',0+$_->{gpu},undef,$_->{uuid},$_->{bdf})} @{amd_rows($raw)}];
}
sub amd_sample {
    my ($inventory,$static,$raw)=@_;my %info=map {$_->{gpu}=>$_} @$static;my %devices=map {$_->{index}=>$_} @$inventory;
    my @out;
    for my $m (@{amd_rows($raw)}) {
        die 'AMD-SMI inventory changed' unless $devices{$m->{gpu}};
        die 'Unsupported AMD-SMI metric schema' unless grep {exists $m->{$_}} qw(mem_usage usage temperature fan power);
        my %r=%{$devices{$m->{gpu}}};my $s=$info{$m->{gpu}}||{};
        my $asic=ref($s->{asic}) eq 'HASH'?$s->{asic}:{};
        $r{name}=string($asic->{market_name})//$r{name};
        my $mem=ref($m->{mem_usage}) eq 'HASH'?$m->{mem_usage}:{};
        # Vendor implementation divides bytes by 1024*1024 before labeling MB.
        $r{memory_used_mib}=quantity($mem->{used_vram},'MB');
        $r{memory_total_mib}=quantity($mem->{total_vram},'MB');
        my $usage=ref($m->{usage}) eq 'HASH'?$m->{usage}:{};
        $r{utilization_percent}=quantity($usage->{gfx_activity},'%');
        my $temp=ref($m->{temperature}) eq 'HASH'?$m->{temperature}:{};
        $r{temperature_c}=quantity($temp->{edge},'C');my $sensor='edge';
        if (!defined $r{temperature_c}) {$r{temperature_c}=quantity($temp->{hotspot},'C');$sensor='hotspot';}
        my $fan=ref($m->{fan}) eq 'HASH'?$m->{fan}:{};$r{fan_percent}=quantity($fan->{usage},'%');
        my $power=ref($m->{power}) eq 'HASH'?$m->{power}:{};
        $r{power_w}=quantity($power->{socket_power},'W');
        my $limit=ref($s->{limit}) eq 'HASH'?$s->{limit}:{};
        my $ppt=ref($limit->{ppt0}) eq 'HASH'?$limit->{ppt0}:{};
        $r{power_limit_w}=quantity($ppt->{socket_power_limit},'W');
        $r{scope}='provider_device';
        push @out,finish(\%r,'amdsmi-json-units',{memory_pool=>'VRAM',temperature_sensor=>$sensor,utilization=>'GFX activity',power_domain=>'socket',power_basis=>'vendor socket reading'});
    }
    die 'AMD-SMI incomplete device sample' unless @out==@$inventory;
    return \@out;
}
sub rocm_rows {
    my ($raw)=@_;my $data=json($raw);die 'Unsupported ROCm-SMI JSON schema' unless ref($data) eq 'HASH';
    my @out;
    for my $k (sort keys %$data) {
        next if $k eq 'system';die 'Unsupported ROCm-SMI device record' unless $k =~ /\Acard(\d+)\z/ && ref($data->{$k}) eq 'HASH';
        push @out,[0+$1,$data->{$k}];
    }
    return \@out;
}
sub rocm_inventory {
    my ($raw)=@_;my @out;
    for my $pair (@{rocm_rows($raw)}) {
        my ($i,$s)=@$pair;die 'Unsupported ROCm-SMI inventory' unless exists $s->{'PCI Bus'} || exists $s->{'Unique ID'} || exists $s->{'Card Series'};
        my $r=record('AMD','rocm-smi',$i,$s->{'Card Series'},undef,$s->{'PCI Bus'});
        my $id=string($s->{'Unique ID'});$r->{provider_unique_id}=$id if defined($id) && $id =~ /\A0x[0-9a-f]+\z/i && $id !~ /\A0x0+\z/;
        push @out,$r;
    }
    return \@out;
}
sub rocm_sample {
    my ($inventory,$raw)=@_;my %devices=map {$_->{index}=>$_} @$inventory;my @out;
    for my $pair (@{rocm_rows($raw)}) {
        my ($i,$m)=@$pair;die 'ROCm-SMI inventory changed' unless $devices{$i};my %r=%{$devices{$i}};
        die 'Unsupported ROCm-SMI metric schema' unless grep {exists $m->{$_}} ('VRAM Total Used Memory (B)','GPU use (%)','Fan speed (%)','Temperature (Sensor edge) (C)','Temperature (Sensor junction) (C)','Average Graphics Package Power (W)','Current Socket Graphics Package Power (W)');
        for my $p (['memory_used_mib','VRAM Total Used Memory (B)'],['memory_total_mib','VRAM Total Memory (B)']) {
            my $n=number($m->{$p->[1]});$r{$p->[0]}=$n/1048576 if defined $n;
        }
        $r{utilization_percent}=number($m->{'GPU use (%)'});$r{fan_percent}=number($m->{'Fan speed (%)'});
        my $sensor=exists($m->{'Temperature (Sensor edge) (C)'})?'edge':'junction';
        $r{temperature_c}=number($m->{'Temperature (Sensor '.$sensor.') (C)'});
        my $key=exists($m->{'Current Socket Graphics Package Power (W)'})?'Current Socket Graphics Package Power (W)':'Average Graphics Package Power (W)';
        $r{power_w}=number($m->{$key});$r{scope}='provider_device';
        push @out,finish(\%r,'rocmsmi-card-json',{memory_pool=>'VRAM',temperature_sensor=>$sensor,utilization=>'GPU busy',power_domain=>'graphics package',power_basis=>$key =~ /^Current/?'current socket':'average'});
    }
    die 'ROCm-SMI incomplete device sample' unless @out==@$inventory;
    return \@out;
}
# CSV parsing is independent of NVIDIA's existing parser. Quoted names may
# contain commas/escaped quotes; malformed quoting or column counts fail closed.
sub csv {
    my ($raw)=@_;my @rows;
    for my $line (split /\r?\n/,text($raw)) {
        next if $line =~ /^\s*$/;my @row;
        while (1) {
            $line =~ s/^\s*//;my $v;
            if ($line =~ s/^"((?:[^"]|"")*)"\s*(?=,|$)//) {$v=$1;$v =~ s/""/"/g;}
            elsif ($line =~ s/^([^",]*)//) {$v=$1;$v =~ s/\s+$//;}
            else {die 'Malformed GPU CSV';}
            push @row,$v;last if $line eq '';
            die 'Malformed GPU CSV' unless $line =~ s/^,//;
            if ($line eq '') {push @row,'';last;}
        }
        push @rows,\@row;
    }
    return \@rows;
}
sub intel_inventory {
    my ($raw)=@_;my $data=json($raw);die 'Unsupported XPU-SMI discovery schema' unless ref($data) eq 'HASH' && exists($data->{device_list});
    return [] unless defined($data->{device_list});
    die 'Unsupported XPU-SMI discovery schema' unless ref($data->{device_list}) eq 'ARRAY';
    my (%seen,@out);
    for my $d (@{$data->{device_list}}) {
        die 'Unsupported XPU-SMI device record' unless ref($d) eq 'HASH' && defined($d->{device_id}) && $d->{device_id} =~ /\A\d+\z/ && !$seen{$d->{device_id}}++;
        next if defined($d->{device_type}) && $d->{device_type} !~ /\A(?:(?:Integrated|Discrete) )?GPU\z/;
        push @out,record('Intel','xpu-smi',0+$d->{device_id},$d->{device_name},$d->{uuid},$d->{pci_bdf_address});
    }
    return \@out;
}
our @INTEL_FIELDS=qw(index uuid name memory.used memory.total temperature.gpu fan.speed utilization.gpu power.draw power.limit);
sub intel_sample {
    my ($inventory,$fields,$raw)=@_;my %devices=map {$_->{index}=>$_} @$inventory;my (%seen,@out);
    my %map=('memory.used'=>'memory_used_mib','memory.total'=>'memory_total_mib','temperature.gpu'=>'temperature_c','fan.speed'=>'fan_percent','utilization.gpu'=>'utilization_percent','power.draw'=>'power_w','power.limit'=>'power_limit_w');
    for my $cols (@{csv($raw)}) {
        die 'Unsupported XPU-SMI CSV columns' unless @$cols==@$fields;
        my %m;@m{@$fields}=@$cols;
        my $i=$m{index};die 'XPU-SMI inventory changed' unless defined($i) && $i =~ /\A\d+\z/ && $devices{$i} && !$seen{$i}++;
        my %r=%{$devices{$i}};
        die 'XPU-SMI UUID changed' if uuid($m{uuid}) && $r{uuid} && uuid($m{uuid}) ne $r{uuid};
        $r{uuid}=uuid($m{uuid})//$r{uuid};$r{name}=string($m{name})//$r{name};
        $r{$map{$_}}=number($m{$_}) for keys %map;
        $r{scope}='provider_device';
        push @out,finish(\%r,'xpusmi-field-csv',{memory_pool=>'provider device memory',temperature_sensor=>'GPU core',utilization=>'busiest engine',power_domain=>'card',power_basis=>'sample average'});
    }
    die 'XPU-SMI incomplete device sample' unless @out==@$inventory;
    return \@out;
}
# A separate JSON fallback for the documented stats schema. Tile measurements
# become device readings only when detailed discovery proves a single tile.
# Older XPUM_STATS-style payloads are deliberately not guessed into this shape.
sub intel_detail {
    my ($r,$raw)=@_;my $d=json($raw);
    die 'Unsupported XPU-SMI detailed discovery schema' unless ref($d) eq 'HASH' && defined($d->{device_id}) && $d->{device_id} eq $r->{index};
    die 'XPU-SMI UUID changed' if uuid($d->{uuid}) && $r->{uuid} && uuid($d->{uuid}) ne $r->{uuid};
    die 'XPU-SMI inventory changed' if bdf($d->{pci_bdf_address}) && $r->{pci_bus_id} && bdf($d->{pci_bdf_address}) ne $r->{pci_bus_id};
    my %out=%$r;$out{uuid}=uuid($d->{uuid})//$r->{uuid};$out{pci_bus_id}=bdf($d->{pci_bdf_address})//$r->{pci_bus_id};
    $out{_tiles}=number($d->{number_of_tiles});
    my $bytes=number($d->{memory_physical_size_byte});$out{memory_total_mib}=$bytes/1048576 if defined $bytes;
    return \%out;
}
sub intel_stats_sample {
    my ($r,$raw)=@_;my $d=json($raw);
    die 'Unsupported XPU-SMI stats JSON schema' unless ref($d) eq 'HASH' && defined($d->{device_index}) && $d->{device_index} eq $r->{index};
    die 'XPU-SMI inventory changed' if bdf($d->{pci_bdf}) && $r->{pci_bus_id} && bdf($d->{pci_bdf}) ne $r->{pci_bus_id};
    die 'Unsupported XPU-SMI stats JSON schema' unless grep {ref($d->{$_}) eq 'HASH'} qw(memory temperature utilization fan power);
    my %out=%$r;
    if (defined($r->{_tiles}) && $r->{_tiles}==1) {
        my $get=sub {my ($a,$b,$c)=@_;return undef unless ref($d->{$a}) eq 'HASH' && ref($d->{$a}{$b}) eq 'HASH';
            my $v=$d->{$a}{$b}{tile_0};return $c && ref($v) eq 'HASH'?number($v->{$c}):!$c?number($v):undef;};
        $out{memory_used_mib}=$get->('memory','used_mib','current');
        $out{temperature_c}=$get->('temperature','gpu_core_celsius','current');
        $out{utilization_percent}=$get->('utilization','gpu_percent',undef);
    }
    delete $out{_tiles};
    return finish(\%out,'xpusmi-stats-json',{memory_pool=>'provider device memory; single-tile measurements only',temperature_sensor=>'GPU core',utilization=>'single-tile GPU average',power_domain=>'unverified; omitted'});
}
1;
