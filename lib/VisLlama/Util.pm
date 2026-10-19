package VisLlama::Util;

# Small shared encoding, quoting and argument helpers. Windows shell quoting
# and PowerShell literal quoting are different contracts; use the matching helper.
use strict;
use warnings;

use JSON::PP ();
use VisLlama::Command ();

use Exporter 'import';
our @EXPORT_OK = qw(jtrue jfalse);

# -----------------------------------------------------------------------------
# JSON boolean helpers used when constructing API/config payloads.
# -----------------------------------------------------------------------------
sub jtrue  { JSON::PP::true }

# -----------------------------------------------------------------------------
# JSON boolean helpers used when constructing API/config payloads.
# -----------------------------------------------------------------------------
sub jfalse { JSON::PP::false }

# -----------------------------------------------------------------------------
# Quote one argument for a Windows command line.
# -----------------------------------------------------------------------------
sub shell_quote_win {
    my ($s) = @_;
    $s //= '';
    $s =~ s/"/\\"/g;
    return qq{"$s"};
}

# -----------------------------------------------------------------------------
# Quote one value for embedding in generated PowerShell.
# -----------------------------------------------------------------------------
sub ps_quote {
    my ($s) = @_;
    $s //= '';
    $s =~ s/'/''/g;
    return "'$s'";
}

# -----------------------------------------------------------------------------
# Run a short command synchronously and capture stdout/stderr.
# -----------------------------------------------------------------------------
sub capture_command {
    if (defined($_[0]) && $_[0] =~ m{\Adocker://}) {require VisLlama::Docker;return VisLlama::Docker::probe(@_);}
    return VisLlama::Command::capture(0,@_);
}

# Keep stdout separate for structured PowerShell output. On Windows,
# redirecting progress/stderr into stdout can wrap JSON in CLIXML.
sub capture_command_stdout {
    if (defined($_[0]) && $_[0] =~ m{\Adocker://}) {require VisLlama::Docker;return VisLlama::Docker::probe(@_);}
    return VisLlama::Command::capture(1,@_);
}

# -----------------------------------------------------------------------------
# Escape text before embedding it into generated HTML.
# -----------------------------------------------------------------------------
sub html_escape {
    my ($s) = @_;
    $s //= '';
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    $s =~ s/'/&#39;/g;
    return $s;
}

# -----------------------------------------------------------------------------
# Remove a named CLI option (and its value) from an argument vector.
# -----------------------------------------------------------------------------
sub strip_arg_with_value {
    my ($args, $target) = @_;
    my @out;
    for (my $i = 0; $i < @$args; $i++) {
        my $v = $args->[$i];
        if (defined($v) && ($v eq $target || $v =~ /^\Q$target\E=/)) {
            if ($v eq $target && $i + 1 < @$args && defined($args->[$i + 1]) && $args->[$i + 1] !~ /^--/) {
                $i++;
            }
            next;
        }
        push @out, $v;
    }
    return \@out;
}

1;
