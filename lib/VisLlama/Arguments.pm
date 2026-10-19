package VisLlama::Arguments;

# Normalize the legacy one-entry-per-line request representation at the server
# boundary. Already separated CLI values remain literal, including Windows paths.
# This is not shell parsing: one option/value pair may occupy a combined entry.
use strict;
use warnings;

sub invalid { die 'Invalid extra arguments. Use one --option value per line and review the command preview.'; }
sub normalize {
    my ($args)=@_;
    invalid() unless ref($args) eq 'ARRAY';
    my @out;
    for (my $i=0;$i<@$args;$i++) {
        my $arg=$args->[$i];
        invalid() unless defined($arg) && !ref($arg) && $arg !~ /[\r\n\x00]/;
        # Only split at an option boundary. A separate path/value containing
        # spaces must never be split or have literal quotes removed.
        if ($arg =~ /\A(--[A-Za-z_][A-Za-z0-9_.-]*)[ \t]+(.+)\z/s) {
            my ($flag,$value)=($1,$2);
            $value =~ s/[ \t]+\z//;
            if ($value =~ /\A(["'])/) {
                my $quote=$1;
                invalid() unless length($value)>=2 && substr($value,-1) eq $quote;
                $value=substr($value,1,-1);
                $value =~ s/\\\Q$quote\E/$quote/g;
            } else {
                invalid() if $value =~ /(?:\A|\s)--[A-Za-z_]/;
            }
            invalid() if $value =~ /[\x00-\x08\x0b\x0c\x0e-\x1f]/;
            push @out,$flag,$value;
            next;
        }
        push @out,$arg;
        # Preserve a following explicit value exactly. Boolean arity validation
        # remains with the catalog/engine, which already owns that behavior.
        if ($arg =~ /\A--?[A-Za-z_][A-Za-z0-9_.-]*\z/ && $i+1<@$args) {
            my $value=$args->[$i+1];
            if (defined($value) && !ref($value) && $value !~ /^--/) {
                invalid() if $value =~ /[\r\n\x00]/;
                push @out,$value;$i++;
            }
        }
    }
    return \@out;
}

1;
