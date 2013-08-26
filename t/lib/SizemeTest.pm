package SizemeTest;

use strict;
use warnings;

use Carp;
use Config;
use Getopt::Long;
use Data::Dumper;
use File::Spec;
use File::Temp qw(tempfile);
use Scalar::Util qw(looks_like_number);
use List::Util qw(shuffle);

use Test::More;

use base qw(Exporter);
our @EXPORT = qw(
    run_test_group
    run_command
    run_perl_command
);

use ExtUtils::testlib;
use Devel::SizeMe::Core; # for Devel::SizeMe::TestWrite

#use Devel::NYTProf::Data;
#use Devel::NYTProf::Reader;
#use Devel::NYTProf::Util qw(strip_prefix_from_paths html_safe_filename);
#use Devel::NYTProf::Run qw(perl_command_words);

my $diff_opts = ($Config{osname} eq 'MSWin32') ? '-c' : '-u';

chdir('t') if -d 't';

my $bindir = (grep {-d} qw(./blib/script ../blib/script))[0] || do {
    my $bin = (grep {-d} qw(./bin ../bin))[0]
        or die "Can't find scripts";
    warn "Couldn't find blib/script directory, so using $bin";
    $bin;
};
my $sizeme_store   = File::Spec->catfile($bindir, "sizeme_store.pl");

my $this_perl = $^X;
$this_perl .= $Config{_exe} if $^O ne 'VMS' and $this_perl !~ m/$Config{_exe}$/i;
# turn ./perl into ../perl, because of chdir(t) above.
$this_perl = ".$this_perl" if $this_perl =~ m|^\./|;


=pod
foo.t
    look for foo-*.tst
    perform to generate foo-*.smt_new and compare with foo-*.smt
    generate .dot_new
=cut

# execute a group of tests (t/testFoo.*) - calls plan()
sub run_test_group {
    my (%opts) = @_;

    # split lines on commas and skip comments
    my @steps;
    for my $line (@{$opts{lines}}) {
        chomp $line;
        next if $line =~ m/^\s*#/;
        my ($action, @args) = split /,/, $line, -1;
        for my $arg (@args) {
            if (looks_like_number($arg)) {
                next;
            }
            elsif ($arg =~ /^'(.*)'$/) {
                $arg = $1;
            }
            elsif (1) {
                my $fullname = "Devel::SizeMe::Core::$arg";
                no strict 'refs';
                my $value = &$fullname();
                $arg = $value;
            }
        }
        push @steps, [ $action, @args ];
    }

    # obtain group from file name
    my $group = ((caller)[1] =~ /([^\/\\]+)\.t$/) ? $1
        : croak "Can't determine test group";

    # .smt is "SizeMe Token" file
    my $smt_file_old = "$group.smt";
    my $smt_file_new = "$smt_file_old\_new";
    unlink <$group.*_new>; # delete all _new files for this group
    is -s $smt_file_new, undef, "$smt_file_new should not exist";

    # perform the steps
    local $ENV{SIZEME} = $smt_file_new;
    Devel::SizeMe::TestWrite::perform(\@steps);

    # check the raw token output
    ok -s $smt_file_new, "$smt_file_new should not be empty";
    is_file_content_same($smt_file_new, $smt_file_old, 'tokens should match');

    # find all the output formats, generate and compare them
    my @outputs = grep { !m/\.(t|smt|\w+_new)$/ } <$group.*>;
    note "Testing outputs: @outputs";
    for my $output_old (@outputs) {
        my $output_new = $output_old."_new";
        my $type = (split /\./, $output_old)[-1];
        if ($type eq 'dot') {
        }
        elsif ($type eq 'gexf') {
        }
        else {
            warn "$output_old ignored - unknown type '$type'";
            next;
        }
        run_perl_command("$sizeme_store --$type $output_new $smt_file_old");
        ok -s $output_new, "$output_new should not be empty";
        is_file_content_same($output_new, $output_old, "$output_new should match $output_old");
    }
}


sub is_file_content_same {
    my ($got_file, $exp_file, $testname) = @_;

    my @got = slurp_file($got_file); chomp @got;
    my @exp = slurp_file($exp_file); chomp @exp;

    is_deeply(\@got, \@exp, $testname)
        ? unlink($got_file)
        : diff_files($exp_file, $got_file, $got_file."_patch");
}


sub diff_files {
    my ($old_file, $new_file, $newp_file) = @_;

    # we don't care if this fails, it's just an aid to debug test failures
    my @opts = split / /, $ENV{NYTPROF_DIFF_OPTS} || $diff_opts;    # e.g. '-y'
    system("cmp -s $new_file $newp_file || diff @opts $old_file $new_file 1>&2");
}


sub slurp_file {    # individual lines in list context, entire file in scalar context
    my ($file) = @_;
    open my $fh, "<", $file or croak "Can't open $file: $!";
    return <$fh> if wantarray;
    local $/ = undef;    # slurp;
    return <$fh>;
}


sub run_command {
    my ($cmd, $show_stdout) = @_;
    #warn "NYTPROF=$ENV{NYTPROF}\n" if $opts{v} && $ENV{NYTPROF};
    local $ENV{PERL5LIB} = join($Config{path_sep}, @INC);
    #warn "$cmd\n" if $opts{v};
    local *RV;
    open(RV, "$cmd |") or die "Can't execute $cmd: $!\n";
    my @results = <RV>;
    my $ok = close RV;
    if (not $ok) {
        warn "Error status $? from $cmd!\n";
        #warn "NYTPROF=$ENV{NYTPROF}\n" if $ENV{NYTPROF} and not $opts{v};
        $show_stdout = 1;
        sleep 2;
    }
    if ($show_stdout) { warn $_ for @results }
    return $ok;
}


# some tests use profile_this() in Devel::NYTProf::Run
sub run_perl_command {
    my ($cmd, $show_stdout) = @_;
    my @perl = ($this_perl);
    run_command("@perl $cmd", $show_stdout);
}

1;

__END__

sub run_test {
    my ($test, $env) = @_;
    my $tag = join " ", map { ($_ ne 'file') ? "$_=$env->{$_}" : () } sort keys %$env;

    #print $test . '.'x (20 - length $test);
    $test =~ / (.+?) \. (?:(\d)\.)? (\w+) $/x or do {
        warn "Can't parse test filename '$test'";
        return;
    };
    my ($basename, $fork_seqn, $type) = ($1, $2 || 0, $3);
    #warn "($basename, $fork_seqn, $type)\n";

    my $profile_datafile = $NYTPROF_TEST{file};
    my $test_datafile = (profile_datafiles($profile_datafile))[$fork_seqn];
    my $outdir = $basename.'_outdir';

    if ($type eq 'p') {
        unlink_old_profile_datafiles($profile_datafile);
        profile($test, $profile_datafile)
            or die "Profiling $test failed\n";

        if ($opts{html}) {
            my $htmloutdir = "/tmp/$outdir";
            unlink <$htmloutdir/*>;
            my $cmd = "$perl $nytprofhtml --file=$profile_datafile --out=$htmloutdir";
            $cmd .= " --open" if $opts{open};
            run_command($cmd);
        }
    }
    elsif ($type eq 'rdt') {
        verify_data($test, $tag, $test_datafile);

        if ($opts{mergerdt}) { # run the file through nytprofmerge
            my $merged = "$profile_datafile.merged";
            my $merge_cmd = "$perl $nytprofmerge -v --out=$merged $test_datafile";
            warn "$merge_cmd\n";
            system($merge_cmd) == 0
                or die "Error running $merge_cmd\n";
            verify_data($test, "$tag (merged)", $merged);
            unlink $merged;
        }
    }
    elsif ($type eq 'calls') {
        if ($env->{calls}) {
            verify_calls_report($test, $tag, $test_datafile, $outdir);
        }
        else {
            pass("no calls");
        }
    }
    elsif ($type eq 'x') {
        mkdir $outdir or die "mkdir($outdir): $!" unless -d $outdir;
        unlink <$outdir/*>;

        verify_csv_report($test, $tag, $test_datafile, $outdir);
    }
    elsif ($type =~ /^(?:pl|pm|new|outdir)$/) {
        # skip; handy for "test.pl t/test01.*"
    }
    else {
        warn "Unrecognized extension '$type' on test file '$test'\n";
    }

    if ($opts{abort}) {
        my $test_builder = Test::More->builder;
        my @summary = $test_builder->summary;
        BAIL_OUT("Aborting after test failure")
            if grep { !$_ } @summary;
    }
}


sub run_command {
    my ($cmd, $show_stdout) = @_;
    warn "NYTPROF=$ENV{NYTPROF}\n" if $opts{v} && $ENV{NYTPROF};
    warn "$cmd\n" if $opts{v};
    local *RV;
    open(RV, "$cmd |") or die "Can't execute $cmd: $!\n";
    my @results = <RV>;
    my $ok = close RV;
    if (not $ok) {
        warn "Error status $? from $cmd!\n";
        warn "NYTPROF=$ENV{NYTPROF}\n" if $ENV{NYTPROF} and not $opts{v};
        $show_stdout = 1;
        sleep 2;
    }
    if ($show_stdout) { warn $_ for @results }
    return $ok;
}


# some tests use profile_this() in Devel::NYTProf::Run
sub run_perl_command {
    my ($cmd, $show_stdout) = @_;
    my @perl = perl_command_words(skip_sitecustomize => 1);
    run_command("@perl $cmd", $show_stdout);
}


sub profile { # TODO refactor to use run_perl_command()?
    my ($test, $profile_datafile) = @_;

    my @perl = perl_command_words(skip_sitecustomize => 1);
    my $cmd = "@perl $opts{profperlopts} $test";
    return ok run_command($cmd), "$test runs ok under the profiler";
}


sub verify_data {
    my ($test, $tag, $profile_datafile) = @_;

    my $profile = eval { Devel::NYTProf::Data->new({filename => $profile_datafile}) };
    if ($@) {
        diag($@);
        fail($test);
        return;
    }

    SKIP: {
        skip 'Expected profile data does not have VMS paths', 1
            if $^O eq 'VMS' and $test =~ m/test60|test14/i;
        $profile->normalize_variables(1); # and options
        dump_profile_to_file($profile, $test.'_new', $test.'_newp');
        is_file_content_same($test.'_new', $test, "$test match generated profile data for $tag");
    }
}

sub is_file_content_same {
    my ($got_file, $exp_file, $testname) = @_;

    my @got = slurp_file($got_file); chomp @got;
    my @exp = slurp_file($exp_file); chomp @exp;

    is_deeply(\@got, \@exp, $testname)
        ? unlink($got_file)
        : diff_files($exp_file, $got_file, $got_file."_patch");
}


sub dump_data_to_file {
    my ($profile, $file) = @_;
    open my $fh, ">", $file or croak "Can't open $file: $!";
    local $Data::Dumper::Indent   = 1;
    local $Data::Dumper::Sortkeys = 1;
    print $fh Data::Dumper->Dump([$profile], ['expected']);
    return;
}


sub dump_profile_to_file {
    my ($profile, $file, $rename_existing) = @_;
    rename $file, $rename_existing or warn "rename($file, $rename_existing): $!"
        if $rename_existing && -f $file;
    open my $fh, ">", $file or croak "Can't open $file: $!";
    $profile->dump_profile_data(
        {   filehandle => $fh,
            separator  => "\t",
            skip_fileinfo_hook => sub {
                my $fi = shift;
                return 1 if $fi->filename =~ /(AutoLoader|Exporter)\.pm$/ or $fi->filename =~ m!^/\.\.\./!;
                return 0;
            },
        }
    );
    return;
}


sub verify_calls_report {
    my ($test, $tag, $profile_datafile, $outdir) = @_;
    my $got_file = "${test}_new";
    note "generating $got_file";
    run_command("$perl $nytprofcalls $profile_datafile -stable --calls > $got_file");
    is_file_content_same($got_file, $test, "$test match generated calls data for $tag");
}


sub verify_csv_report {
    my ($test, $tag, $profile_datafile, $outdir) = @_;

    # generate and parse/check csv report

    # determine the name of the generated csv file
    my $csvfile = $test;

    # fork tests will still report using the original script name
    $csvfile =~ s/\.\d\./.0./;

    # foo.p  => foo.p.csv  is tested by foo.x
    # foo.pm => foo.pm.csv is tested by foo.pm.x
    $csvfile =~ s/\.x//;
    $csvfile .= ".p" unless $csvfile =~ /\.p/;
    $csvfile = html_safe_filename($csvfile);
    $csvfile = "$outdir/${csvfile}-1-line.csv";
    unlink $csvfile;

    my $cmd = "$perl $nytprofcsv --file=$profile_datafile --out=$outdir";
    ok run_command($cmd), "nytprofcsv runs ok";

    my @got      = slurp_file($csvfile);
    my @expected = slurp_file($test);

    if ($opts{d}) {
        print "GOT:\n";
        print @got;
        print "EXPECTED:\n";
        print @expected;
        print "\n";
    }

    my $index = 0;
    foreach (@expected) {
        if ($expected[$index++] =~ m/^# Version/) {
            splice @expected, $index - 1, 1;
        }
    }

    my $automated_testing = $ENV{AUTOMATED_TESTING}
        # also try to catch some cases where AUTOMATED_TESTING isn't set
        # like http://www.cpantesters.org/cpan/report/07588221-b19f-3f77-b713-d32bba55d77f
                        || ($ENV{PERL_BATCH}||'') eq 'yes';
    # if it was slower than expected then we're very generous, to allow for
    # slow systems, e.g. cpan-testers running in cpu-starved virtual machines.
    # e.g., http://www.nntp.perl.org/group/perl.cpan.testers/2009/06/msg4227689.html
    my $max_time_overrun_percentage = ($automated_testing) ? 400 : 200;
    my $max_time_underrun_percentage = 80;

    my @accuracy_errors;
    $index = 0;
    my $limit = scalar(@got) - 1;
    while ($index < $limit) {
        $_ = shift @got;

        next if m/^# Version/;    # Ignore version numbers

        s/^([0-9.]+),([0-9.]+),([0-9.]+),(.*)$/0,$2,0,$4/o;
        my $t0  = $1;
        my $c0  = $2;
        my $tc0 = $3;

        if (    defined $expected[$index]
            and 0 != $expected[$index] =~ s/^~([0-9.]+)/0/
            and $c0               # protect against div-by-0 in some error situations
            )
        {
            my $expected = $1;
            my $percent  = int(($t0 / $expected) * 100);    # <100 if faster, >100 if slower

            # Test aproximate times
            push @accuracy_errors,
                  "$test line $index: got $t0 expected approx $expected for time ($percent%)"
                if ($percent < $max_time_underrun_percentage)
                or ($percent > $max_time_overrun_percentage);

            my $tc = $t0 / $c0;
            push @accuracy_errors, "$test line $index: got $tc0 expected ~$tc for time/calls"
                if abs($tc - $tc0) > 0.00002;   # expected to be very close (rounding errors only)
        }

        push @got, $_;
        $index++;
    }

    if ($opts{d}) {
        print "TRANSFORMED TO:\n";
        print @got;
        print "\n";
    }

    chomp @got;
    chomp @expected;
    is_deeply(\@got, \@expected, "$test match generated CSV data for $tag") or do {
        spit_file($test.'_new', join("\n", @got,''), $test.'_newp');
        diff_files($test, $test.'_new', $test.'_newp');
    };
    is(join("\n", @accuracy_errors), '', "$test times should be reasonable");
}


sub pop_times {
    my $hash = shift || return;

    foreach my $key (keys %$hash) {
        shift @{$hash->{$key}};
        pop_times($hash->{$key}->[1]);
    }
}


sub number_of_tests {
    my $total_tests = 0;
    for (@_) {
        next unless m/\.(\w+)$/;
        my $tests = $text_extn_info->{$1}{tests};
        warn "Unknown test type '$1' for test file '$_'\n" if not defined $tests;
        $total_tests += $tests if $tests;
    }
    return $total_tests;
}


sub slurp_file {    # individual lines in list context, entire file in scalar context
    my ($file) = @_;
    open my $fh, "<", $file or croak "Can't open $file: $!";
    return <$fh> if wantarray;
    local $/ = undef;    # slurp;
    return <$fh>;
}


sub spit_file {
    my ($file, $content, $rename_existing) = @_;
    rename $file, $rename_existing or warn "rename($file, $rename_existing): $!"
        if $rename_existing && -f $file;
    open my $fh, ">", $file or croak "Can't open $file: $!";
    print $fh $content;
    close $fh or die "Error closing $file: $!";
}


sub profile_datafiles {
    my ($filename) = @_;
    croak "No filename specified" unless $filename;
    my @profile_datafiles = glob("$filename*");

    # sort to ensure datafile without pid suffix is first
    @profile_datafiles = sort @profile_datafiles;
    return @profile_datafiles;    # count in scalar context
}

sub unlink_old_profile_datafiles {
    my ($filename) = @_;
    my @profile_datafiles = profile_datafiles($filename);
    print "Unlinking old @profile_datafiles\n"
        if @profile_datafiles and $opts{v};
    1 while unlink @profile_datafiles;
}


sub count_of_failed_tests {
    my @details = Test::Builder->new->details;
    return scalar grep { not $_->{ok} } @details;
}


1;

# vim:ts=8:sw=4:et
