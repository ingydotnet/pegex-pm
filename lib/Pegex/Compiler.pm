package Pegex::Compiler;
use Pegex::Base;

use Pegex::Parser;
use Pegex::Pegex::Grammar;
use Pegex::Pegex::AST;
use Pegex::Grammar::Atoms;

use constant DEBUG => $ENV{PERL_PEGEX_COMPILER_DEBUG};

sub _debug {
    my ($label, @data) = @_;
    print STDERR "$label: ";
    print STDERR _dumper_nice(@data > 1 ? \@data : $data[0]);
}

has tree => ();

sub compile {
    my ($self, $grammar, @rules) = @_;

    # Global request to use the Pegex bootstrap compiler
    if ($Pegex::Bootstrap) {
        require Pegex::Bootstrap;
        $self = Pegex::Bootstrap->new;
    }

    @rules = map { s/-/_/g; $_ } @rules;

    $self->parse($grammar);
    $self->combinate(@rules);
    $self->native;

    return $self;
}

sub parse {
    my ($self, $input) = @_;

    my $parser = Pegex::Parser->new(
        grammar => Pegex::Pegex::Grammar->new,
        receiver => Pegex::Pegex::AST->new,
    );

    $self->{tree} = $parser->parse($input);

    return $self;
}

#-----------------------------------------------------------------------------#
# Combination
#-----------------------------------------------------------------------------#
has _tree => ();

sub combinate {
    my ($self, @rule) = @_;
    if (not @rule) {
        if (my $rule = $self->{tree}->{'+toprule'}) {
            @rule = ($rule);
        }
        else {
            return $self;
        }
    }
    $self->{_tree} = {
        map {($_, $self->{tree}->{$_})} grep { /^\+/ } keys %{$self->{tree}}
    };
    DEBUG and _debug "combinate", $self->{tree}, $self->{_tree};
    for my $rule (@rule) {
        $self->combinate_rule($rule);
    }
    DEBUG and _debug "combinate DONE", $self->{_tree};
    $self->{tree} = $self->{_tree};
    delete $self->{_tree};
    return $self;
}

sub combinate_rule {
    my ($self, $rule) = @_;
    DEBUG and _debug "combinate_rule($rule)";
    return if exists $self->{_tree}->{$rule};

    my $object = $self->{_tree}->{$rule} = $self->{tree}->{$rule};
    $self->combinate_object($object);
}

sub combinate_object {
    my ($self, $object) = @_;
    DEBUG and _debug "combinate_object", $object;
    if (exists $object->{'.lit'}) {
        my $got = delete $object->{'.lit'};
        $got =~ s/([^\w\`\%\:\<\/\,\=\;])/\\$1/g;
        $object->{'.rgx'} = $got;
    }
    if (exists $object->{'.rgx'}) {
        $object->{'.rgx'} = $self->combinate_re($object->{'.rgx'});
    }
    elsif (exists $object->{'.ref'}) {
        my $rule = $object->{'.ref'};
        if (exists $self->{tree}{$rule}) {
            $self->combinate_rule($rule);
        }
        else {
            if (my $regex = (Pegex::Grammar::Atoms::atoms)->{$rule}) {
                $self->{tree}{$rule} = { '.rgx' => $regex };
                $self->combinate_rule($rule);
            }
        }
    }
    elsif (exists $object->{'.any'}) {
        for my $elem (@{$object->{'.any'}}) {
            $self->combinate_object($elem);
        }
    }
    elsif (exists $object->{'.all' }) {
        for my $elem (@{$object->{'.all'}}) {
            $self->combinate_object($elem);
        }
    }
    elsif (exists $object->{'.err' }) {
    }
    else {
        require YAML::PP;
        die "Can't combinate:\n" .
            YAML::PP->new(schema => ['Core', 'Perl'])->dump_string($object);
    }
}

sub combinate_re {
    my ($self, $re) = @_;
    DEBUG and _debug "combinate_re", $re;
    my $atoms = Pegex::Grammar::Atoms->atoms;
    my $prev = $re;
    while (1) {
        DEBUG and _debug "combinate_re sofar($re)";
        $re =~ s[(?<!\\)(~+)]['<ws' . length($1) . '>']ge;
        $re =~ s[<([\w\-]+)>][
            (my $key = $1) =~ s/-/_/g;
            $self->{tree}->{$key} and (
                $self->{tree}->{$key}{'.rgx'} or
                die "'$key' not defined as a single RE"
            )
            or $atoms->{$key}
            or die "'$key' not defined in the grammar"
        ]e;
        last if $re eq $prev;
        $prev = $re;
    }
    return $re;
}

#-----------------------------------------------------------------------------#
# Compile to native Perl regexes
#-----------------------------------------------------------------------------#
sub native {
    my ($self) = @_;
    $self->perl_regexes($self->{tree});
    return $self;
}

sub perl_regexes {
    my ($self, $node) = @_;
    if (ref($node) eq 'HASH') {
        if (exists $node->{'.rgx'}) {
            my $re = $node->{'.rgx'};
            $node->{'.rgx'} = qr/\G$re/;
        }
        else {
            for (keys %$node) {
                $self->perl_regexes($node->{$_});
            }
        }
    }
    elsif (ref($node) eq 'ARRAY') {
        $self->perl_regexes($_) for @$node;
    }
}

#-----------------------------------------------------------------------------#
# Serialization formatter methods
#-----------------------------------------------------------------------------#
sub to_yaml {
    require YAML::PP;
    my $self = shift;
    my $yaml = YAML::PP->new(schema => ['Core', 'Perl'])
                       ->dump_string($self->tree);
    $yaml =~ s/\n *(\[\]\n)/ $1/g; # Work around YAML::PP formatting issue
    return $yaml;
}

sub to_json {
    require JSON::PP;
    my $self = shift;
    return JSON::PP->new->utf8->canonical->pretty->encode($self->tree);
}

sub _dumper_nice {
    my ($data) = @_;
    require Data::Dumper;
    no warnings 'once';
    local $Data::Dumper::Terse = 1;
    local $Data::Dumper::Indent = 1;
    local $Data::Dumper::Sortkeys = 1;
    return Data::Dumper::Dumper($data);
}

sub to_perl {
    my $self = shift;
    my $perl = _dumper_nice($self->tree);
    $perl =~ s/\?\^u?:/?-xism:/g; # the "u" is perl 5.14-18 equiv of /u
    $perl =~ s!(\.rgx.*?qr/)\(\?-xism:(.*)\)(?=/)!$1$2!g;
    $perl =~ s!/u$!/!gm; # perl 5.20+ put /u, older perls don't understand
    die "to_perl failed with non compatible regex in:\n$perl"
        if $perl =~ /\?\^/;
    return $perl;
}

1;
