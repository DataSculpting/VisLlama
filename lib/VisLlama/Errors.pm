package VisLlama::Errors;
use strict;
use warnings;
use JSON::PP ();
use File::Spec;
use Fcntl qw(:DEFAULT :flock);
use Digest::SHA qw(sha256_hex);
use Encode qw(encode);
use Time::HiRes qw(time);
use VisLlama::Paths ();
use VisLlama::Context qw($STATE);

# Public messages are application-owned literals, never fragments of exceptions.
# Unknown errors fail closed. The reference locates bounded private diagnostics.
my %MESSAGES = (
 request_failed=>'The operation could not be completed.',
 proxy_error=>'The Router could not complete this request.',
 model_load_error=>'The model could not be loaded. Check its configuration and available resources.',
 context_size_exceeded=>'The conversation exceeds the model context window. Start a new conversation or shorten it.',
 backend_error=>'The inference engine could not complete this request.',
 invalid_request_error=>'The inference engine rejected the request. Check the model and request parameters.',
 stream_error=>'The inference stream ended unexpectedly.',
 process_error=>'A managed process reported an error.',
 reload_error=>'The Router configuration could not be applied. A restart may be required.',
 telemetry_error=>'Hardware telemetry is temporarily unavailable.',
 probe_error=>'The selected build could not be inspected.',
 diagnostic=>'Details are available in the server-side diagnostic log.',
);
my %VALIDATION;
my %RECENT;
my $SERIAL = 0;

# Register only reviewed static validation strings at module load time. This is
# not a pattern scrubber: adding arbitrary exception prefixes here is unsafe.
sub register_validation { $VALIDATION{$_} = 1 for @_; }

sub log_dir { File::Spec->catdir(VisLlama::Paths::app_base_dir(), 'logs') }

sub report {
    my ($detail,$code) = @_;
    local $@;
    $code = 'request_failed' unless defined($code) && exists $MESSAGES{$code};
    my $raw = defined($detail) ? "$detail" : '';
    my $key = sha256_hex(encode('UTF-8',$code . '\0' . $raw));
    my $now = time();
    return $RECENT{$key}{ref} if $RECENT{$key} && $now - $RECENT{$key}{at} < 60;
    %RECENT=() if keys(%RECENT) >= 256;
    my $ref = 'VL-' . substr(sha256_hex(join(':',$now,$$,$SERIAL++,rand(),$key)),0,20);
    # Avoid recording whole requests/headers at call sites. Redact conventional
    # credential assignments even inside an exception or a backend diagnostic.
    $raw =~ s/((?:authorization|proxy-authorization)\s*[:=]\s*)[^\r\n]+/${1}[redacted]/ig;
    $raw =~ s/(\bBearer\s+)[A-Za-z0-9._~+\/-]+=*/${1}[redacted]/ig;
    $raw =~ s/((?:"|')?(?:api[_-]?key|access[_-]?token|control[_-]?token|token|password|secret)(?:"|')?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;}]+)/${1}[redacted]/ig;
    $raw = substr($raw,0,32768) . (length($raw)>32768 ? '\n[truncated]' : '');
    my $record = JSON::PP->new->ascii->canonical->encode({reference=>$ref,code=>$code,at=>scalar(gmtime()),detail=>$raw}) . "\n";
    my $written = eval {
        my $dir=log_dir(); mkdir($dir,0700) unless -d $dir;
        my @t=gmtime(); my $date=sprintf('%04d-%02d-%02d',$t[5]+1900,$t[4]+1,$t[3]);
        my $path=File::Spec->catfile($dir,"diagnostics-$date.jsonl");
        sysopen(my $fh,$path,O_WRONLY|O_APPEND|O_CREAT,0600) or die "log open";
        flock($fh,LOCK_EX) or die "log lock";
        binmode $fh;
        print {$fh} $record or die "log write";
        close($fh) or die "log close";
        1;
    };
    # Failure to write diagnostics must never replace the original failure or
    # expose a log path. STDERR is server-side and is not returned by status.
    if (!$written) { eval { print STDERR $record; }; }
    $RECENT{$key}={at=>$now,ref=>$ref};
    return $ref;
}

sub public_error {
    my ($detail,$code) = @_;
    $code='request_failed' unless defined($code) && exists $MESSAGES{$code};
    my $message=$MESSAGES{$code};
    my $candidate=defined($detail) ? "$detail" : '';
    $candidate =~ s/\s+at\s+[^\r\n]+\s+line\s+\d+[^\r\n]*\s*\z//;
    $candidate =~ s/\s+\z//;
    # Only exact static validation messages survive. Never echo the candidate.
    if ($code eq 'request_failed' && $VALIDATION{$candidate}) {
        ($message) = grep { $_ eq $candidate } keys %VALIDATION;
    }
    if ($code eq 'request_failed') {
        $message='Engine definition is invalid. Review its JSON fields and docs/ENGINES.md.' if $candidate =~ /^Engine definition is invalid\./;
        $message='Engine capability discovery failed. Check the selected executable and Logs / Diagnostics.' if $candidate =~ /^Engine capability discovery failed\./;
        $message='The operation was cancelled.' if $candidate =~ /^Operation cancelled/;
        $message='Controller is busy. Retry after the current operation.' if $candidate =~ /^Controller is busy/;
        $message='A native probe timed out or exceeded its output limit. Check Logs / Diagnostics.' if $candidate =~ /^Native probe (?:timed out|output limit)/;
        $message='Runtime changed. Refresh status and retry the action.' if $candidate =~ /^Runtime changed\./;
        $message='Model preflight failed. Check the selected build, model files, options and GPU visibility group before retrying.' if !$VALIDATION{$candidate} && $candidate =~ /^(?:Unsupported saved option|Build capabilities could not|Model file is missing|A referenced model|Preflight |Model settings changed|Model files changed|Restart Router to apply)/;
        $message='Saved configuration could not be read or published safely. Check Logs / Diagnostics before retrying.' if $candidate =~ /^(?:Invalid saved JSON|Invalid saved model catalog|Invalid publication|Cannot (?:replace|sync|flush|write staged|close staged|lock publication))/;

        $message='Managed processes could not be confirmed stopped. Retry Stop before starting again.' if $candidate =~ /^(?:Managed process termination could not be confirmed;|Could not confirm proxy termination;)/;
        $message='GPU isolation could not be verified. Check the selected build and GPU devices in Logs / Diagnostics.' if $candidate =~ /^GPU isolation could not be verified:/;
        $message='No selected GPU has enough free VRAM above the configured reserve.' if $candidate =~ /^No selected GPU has free VRAM above /;
        $message='The selected GPUs do not have enough available memory. Reduce context or cache precision, free VRAM, or use Adaptive auto-fit.' if $candidate =~ /^Estimated model weights, KV cache and compute memory exceed /;
        $message='A selected device is unavailable in this build. Refresh devices and review the selection.' if $candidate =~ /^Device .+ is not reported by llama.cpp build /;
        $message='Free VRAM could not be measured. Use Adaptive auto-fit or a manual tensor split.' if $candidate =~ /^Cannot read free VRAM for /;
        $message='The chat template file could not be found. Check the selected file.' if $candidate =~ /^Chat template file does not exist on this server:/;
        $message='Cannot delete this build while model presets reference it.' if $candidate =~ /^Cannot delete build while Router Presets reference it:/;
        $message='Docker could not complete the operation. Check Docker access and Logs / Diagnostics.' if $candidate =~ /^Docker command failed|^Docker image pull failed/;
        $message='Docker container ownership or cleanup could not be verified. Retry Stop and check Logs / Diagnostics.' if $candidate =~ /^Docker (?:container ownership|stop is unconfirmed|removal unconfirmed|probe cleanup)/;
    }
    return {message=>$message,code=>$code,reference=>report($detail,$code)};
}

sub public_text {
    my ($detail,$code)=@_;
    return undef unless defined($detail) && length("$detail");
    my $e=public_error($detail,$code);
    return "$e->{message} Reference: $e->{reference}";
}

# Logs are operational diagnostics: retain every ordinary line and its timing,
# severity and native error explanation. Only sensitive substrings are replaced.
# API errors still use the stricter public_error() boundary above; this redactor
# is for the explicitly requested administration log view, not error responses.
sub browser_log {
    my ($raw)=@_;
    return '' unless defined($raw) && length($raw);
    my $text="$raw";
    my $control=$STATE->{router_control_token};
    $text =~ s/\Q$control\E/[redacted]/g if defined($control) && length($control);
    my $name=qr/(?:(?:llama|openai|anthropic)[-_]api[-_]key|aws[-_]secret[-_]access[-_]key|aws[-_]session[-_]token|api[-_]?keys?|access[-_]?token|refresh[-_]?token|control[-_]?token|auth[-_]?token|hf[-_]?token|huggingface[-_]?token|client[-_]?secret|password|passwd|pwd|secret|token)/i;
    my $value=qr/(?:\[[^\]\r\n]*\]|"(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])*'|[^\s,;&}\]\)]+)/;

    # Structured credentials, headers and CLI arguments have different quoting
    # rules. Match their value boundaries without consuming adjacent log fields.
    $text =~ s{((?:["']?)(?:proxy-authorization|authorization|set-cookie|cookie)(?:["']?)[ \t]*[:=][ \t]*)(?:"(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])*'|[^\r\n]+)}{${1}[redacted]}ig;
    $text =~ s{((?<![\w-])["']?$name["']?[ \t]*[:=][ \t]*)$value}{${1}[redacted]}ig;
    my $cli_value=qr/(?:"(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])*'|[^\s;]+)/;
    $text =~ s{((?<![\w-])["']?--$name["']?(?:=|[ \t]+))$cli_value}{${1}[redacted]}ig;
    $text =~ s{(\b(?:Bearer|Basic)[ \t]+)[A-Za-z0-9._~+/=-]+}{${1}[redacted]}ig;
    $text =~ s{(\bhttps?://)[^\s/@]+@}{${1}[redacted]\@}ig;
    $text =~ s{([?&]$name=)[^\s&#"']*}{${1}[redacted]}ig;
    # Recognizable provider keys can also occur without an assignment label.
    $text =~ s{\b(?:sk-[A-Za-z0-9_-]{20,}|hf_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,})\b}{[redacted credential]}g;
    $text =~ s{-----BEGIN ([A-Z ]*PRIVATE KEY)-----.*?(?:-----END \1-----|\z)}{[redacted private key]}sg;

    # Remove source frames without replacing the useful exception explanation.
    $text =~ s{(?:[A-Za-z_]\w*(?:::\w+)+|eval)[ \t]*\([^\r\n]*\)[ \t]+called[ \t]+at[^\r\n]*}{[internal stack frame]}g;
    $text =~ s{\bat[ \t]+[^\r\n]*?\.(?:pm|pl)[ \t]+line[ \t]+\d+(?:,[ \t]*<[^>]*>[ \t]+line[ \t]+\d+)?\.?}{[internal source]}ig;
    $text =~ s{\bat[ \t]+\(eval[ \t]+\d+\)[ \t]+line[ \t]+\d+\.?}{[internal source]}ig;
    $text =~ s{\@INC(?:[ \t]+contains:)?[ \t]*\([^\r\n]*\)}{module search path [redacted]}g;

    # Quoted absolute paths can contain spaces. Unquoted known file extensions
    # cover native/PowerShell diagnostics which often omit path quotes. Preserve
    # a GGUF basename so model-file messages remain useful, but hide directories.
    $text =~ s{(["'])((?:[A-Za-z]:[\\/]|\\\\|/)[^\r\n]*?)\1}{$1 . log_path_label($2) . $1}ge;
    $text =~ s{(?<![\w:/])((?:[A-Za-z]:[\\/]|\\\\)[^\r\n"'<>|]*?\.(?:gguf|pm|pl|ps1|exe|dll|jsonl?|ini|log|txt))(?=[\s:;,\)\]]|\z)}{log_path_label($1)}ige;
    $text =~ s{(?<![\w:/])(?:[A-Za-z]:[\\/]|\\\\)[^\s"'<>|,;\)\]]+}{[path]}g;
    $text =~ s{(?<![\w:/])(/(?!v1(?:/|\b)|api(?:/|\b)|models(?:/|\b))[^\r\n"'<>|]*?\.(?:gguf|pm|pl|ps1|exe|dll|jsonl?|ini|log|txt))(?=[\s:;,\)\]]|\z)}{log_path_label($1)}ige;
    # POSIX filesystem paths have two or more segments. Keep public API routes
    # and HTTP URLs intact: their operational endpoint names are not secrets.
    $text =~ s{(?<![\w:/])(/(?!v1(?:/|\b)|api(?:/|\b)|models(?:/|\b)|health\b|metrics\b)[^\s"'<>|,;\)\]]+/[^\s"'<>|,;\)\]]+)}{log_path_label($1)}ge;
    # Relative Perl source references are private too, including module names
    # in "Can't locate" diagnostics. Native C/C++ routine names remain useful.
    $text =~ s{(?<![\w])(?:[\w.-]+[\\/])*[\w.-]+\.(?:pm|pl)\b}{[internal source]}ig;
    $text =~ s{\bVisLlama(?:::[A-Za-z_]\w*)+}{[internal routine]}g;
    return $text;
}

sub log_path_label {
    my ($path)=@_;
    return $path if $path =~ m{\A/(?:v1|api|models|health|metrics)(?:/|\?|\z)};
    return "[path]/$1" if $path =~ m{([^/\\]+\.gguf)\z}i;
    return '[path]';
}

# Static validation catalog retained from the existing control API.
register_validation(
    'Model file is missing or outside the configured GGUF root',
    'A referenced model, adapter or chat template file is missing',
    'A split GGUF shard is missing',
    'Target Router engine is no longer running',
    'Restart Router to apply the new build or GPU visibility groups.',
    'Preflight expired. Validate the model again.',
    'Model settings changed after preflight. Validate again.',
    'Model files changed after preflight. Validate again.',
    'GPU isolation could not be verified. Check the selected build and GPU devices in Logs / Diagnostics.',
    'GPU selection changed. Apply configuration or restart Router before loading this model.',
    'Calculated placement cannot account for these custom allocation or draft-model options. Use Adaptive auto-fit or Manual mode.',
    'Invalid extra arguments. Use one --option value per line and review the command preview.',
    'Invalid saved model options. Open the model editor and correct its extra arguments.',
    'A llama-server process is already running',
    'A valid llama.cpp build must be selected for this Router Preset',
    'API alias is required',
    'Adaptive auto-fit needs a llama.cpp build supporting --fit-target and --fit; choose a newer build or use Manual mode',
    'Alias may contain only letters, numbers, dot, underscore, colon and hyphen',
    'Asset not found',
    'At least one llama.cpp build must remain configured',
    'Build alias is already used',
    'Build alias is required',
    'Build being edited no longer exists',
    'Build folder does not exist on this server',
    'Build folder is required',
    'Calculated GPU split needs a llama.cpp build supporting --tensor-split',
    'Folder does not exist or cannot be read on this server',
    'GGUF array is too large',
    'GPU memory reserve must be between 256 and 32768 MiB',
    'HTTP threads must be a non-negative integer or blank',
    'Invalid GGUF shard count',
    'Invalid JSON body',
    'Chat template file does not exist on this server.',
    'Cannot delete this build while model presets reference it.',
    'Model catalog contains an invalid or duplicate alias',
    'Model file does not exist',
    'Model is not a calculated split preset',
    'Model must be a .gguf file',
    'Model must be under the GGUF model root',
    'Model name is required',
    'Model path is required',
    'Model root folder does not exist on this server',
    'Model root folder is required',
    'No enabled models are configured. Open Manage Models to add or enable a model.',
    'No running router engine owns this model',
    'Not found',
    'OpenAI compatibility proxy failed to restart',
    'Preset alias is required',
    'Preset not found',
    'Priority order contains a duplicate device',
    'Priority order requires a GGUF model file',
    'Priority order requires a configured llama.cpp build',
    'Priority order supports CUDA devices only',
    'Provide the complete ordered model list',
    'Proxy launcher is unavailable',
    'Router is not running',
    'Router public host is required',
    'Router public port must be between 1 and 65535',
    'Select a readable discovery root',
    'Select at least one CUDA device for priority order',
    'Stop compute is available only while Router mode and its compatibility proxy are running',
    'llama-server executable not found',
    'llama-server executable not found in this build folder',
    'Unauthorized',
    'Unknown API route',
    'Unknown build',
    'Configure at least one llama.cpp build alias before starting',
    'Stop Router before removing a build that is still running.',
    'Stop Router before removing the last build alias.',
    'Docker images are supported only on Linux',
    'Enter an image reference, not a docker run command',
    'Docker requires a local Unix-socket daemon for host model mounts',
    'Docker requires Linux containers',
    'The Docker image does not advertise llama.cpp Router support. Choose an image with --models-preset support.',
    'Build alias contains invalid control characters',
    'Docker could not complete the operation. Check Docker access and Logs / Diagnostics.',
    'Docker container ownership or cleanup could not be verified. Retry Stop and check Logs / Diagnostics.',
    'Unknown llama.cpp build',
    'Unknown or repeated model in load order',
    'Unsupported GGUF array type',
    'Unsupported GGUF version',
    'models-max must be >= 0',
);

1;
