#!/usr/bin/perl
# -*- mode: perl; indent-tabs-mode: t; perl-indent-level: 4 -*-
# vim: autoindent tabstop=4 shiftwidth=4 expandtab softtabstop=4 filetype=perl
#
# Author: Andrew Theurer
#
# This is a wrapper script that will run a benchmark for the user by doing the following:
# - validating the benchmark exists
# - validating the benchmark parameters and pbench parameters (via pbench-gen-iterations)
# - constructing a list of benchmark-iterations (via pbench-gen-iterations)
# - executing those iterations, with N sample-executions per iteration (via pbench-run-iteration)
# - run any post-processing for those executions
# - bundle all the data in a JSON document

use strict;
use warnings;
use File::Basename;
my $pbench_install_dir = $ENV{'pbench_install_dir'};
use lib $ENV{'pbench_lib_dir'};
use File::Path qw(remove_tree);
use PbenchCDM        qw(create_run_doc create_config_osrelease_doc create_config_cpuinfo_doc
                        create_config_netdevs_doc create_config_ethtool_doc create_config_base_doc
                        get_uuid create_bench_iter_doc create_config_doc);
use PbenchBase       qw(get_json_file put_json_file get_benchmark_names get_pbench_run_dir
                        get_pbench_install_dir get_pbench_config_dir get_pbench_bench_config_dir
                        get_benchmark_results_dir get_params remove_params get_hostname
                        begin_run end_run interrupt_run metadata_log_record_iteration
                        get_pbench_datetime);
use PbenchAnsible    qw(ssh_hosts ping_hosts copy_files_to_hosts copy_files_from_hosts
                        remove_files_from_hosts remove_dir_from_hosts create_dir_hosts
                        sync_dir_from_hosts verify_success stockpile_hosts);

my %defaults = (
    "num-samples" => 1,
    "tool-group" => "default",
    "sysinfo" => "default",
    "postprocess-mode" => "html"  # other mode is "cdm"
);

my $pp_only = 0;
my $base_bench_dir = "";

my @benchmarks = get_benchmark_names(get_pbench_bench_config_dir);
# The only required [positional] argument is the benchmark name; verify it now
if (scalar @ARGV == 0) {
    print "You must supply at least one of the following supported benchmark names:\n";
    printf "\t%s\n",  join(" ", @benchmarks);
    exit 1;
}
my $benchmark = shift(@ARGV);
if ($benchmark eq "list") {
    printf "%s\n",  join(" ", @benchmarks);
    exit;
}
my %benchmarks_hash = map { $_ => 1 } @benchmarks;
if (! exists($benchmarks_hash{$benchmark})) {
    print "Unsupported benchmark " . $benchmark . "; please supply one of the following supported benchmark names:\n";
    printf "\t%s\n",  join(" ", @benchmarks);
    exit 1;
}

# The rest of the parameters are --arg=val, most of which we just pass to other scripts,
my %params = get_params(@ARGV);

# determine the common parameters from a group of iterations
sub find_common_parameters {
    my @iterations = @_;

    my %common_parameters;
    my $counter = 1;
    for my $iteration_params (@iterations) {
        $iteration_params =~ s/^\s+(.+)\s+$/$1/;

        my @split_params = split(/\s+/, $iteration_params);

        # count the number of occurences of each parameter key=value
        # pair
        for my $param_piece (@split_params) {
            if (! exists($common_parameters{$param_piece})) {
                $common_parameters{$param_piece} = 1;
            } else {
                $common_parameters{$param_piece}++;
            }
        }

        $counter++;
    }

    # decrement by one since we are post decrementing in the loop
    $counter--;

    for my $key (keys %common_parameters) {
        # if the number of iterations is the same as the count for the
        # key=value pair then the key=value pair is common across all
        # iterations -- so remove key=value pairs where the count is
        # not the same
        if ($common_parameters{$key} != $counter) {
            delete $common_parameters{$key};
        }
    }

    return(%common_parameters);
}

# Prepare for a post-process only mode if detected
if (exists $params{"postprocess-only"} and $params{"postprocess-only"} eq "y") {
    $pp_only = 1;
    printf "found postprocess-only\n";
    delete $params{"postprocess-only"};
    if (exists $params{"postprocess-dir"}) {
        $base_bench_dir = $params{"postprocess-dir"};
        delete $params{"postprocess-dir"};
    } else {
        # Assume already in the base benchmark directory
        $base_bench_dir = `/bin/pwd`;
        chomp $base_bench_dir;
    }
    printf "base_bench_dir: %s\n", $base_bench_dir;
}

# Every benchmark must have at least 1 client, even if the client is the same host as the controller
if (! exists $params{'clients'}) {
    print "You must specify at least 1 client with --clients\n";
    exit 1;
}

# Warn if a few optional but highly recommended params are missing (can also be defined with env vars)
for my $param (qw(user-name user-email user-desc user-tags)) {
    my $env_var = uc $param;
    $env_var =~ s/-/_/g;
    if (! exists $params{$param}) { # if --arg_name was used, $ARG_NAME will not be used
        if (! exists $ENV{$env_var}) {
            printf "\n***** it is highly recommended you do one of the following:\n" .
                   "- export this variable before calling this script %s\n" .
                   "- use this parameter when calling this script: --%s\n\n", $env_var, $param;
            $params{$param} = "";
        } else {
            $params{$param} = $ENV{$env_var};
        }
    }
}

# Apply the Pbench defaults (not the benchmark defaults)
for my $def (keys %defaults) {
    if (! exists $params{$def}) {
        $params{$def} = $defaults{$def};
    }
}

my $date = get_pbench_datetime();

# Prepare all the dirs for the run
if ($pp_only) {
    if (! -e $base_bench_dir) {
        die "Expected the base benchmark directory, [$base_bench_dir], to already exist, since this is a post-process only mode";
    }
} else {
    $base_bench_dir = get_benchmark_results_dir($benchmark, $params{"user-tags"}, $date);
    # Spaces in directories, just don't do it
    $base_bench_dir =~ s/\s+/_/g;
    mkdir("$base_bench_dir");

    # Document the params used for this invocation so one can re-run, and then they can add
    # "--postprocess-only=y --base-bench_dir=$base_bench_dir" if they wish to not run but
    # only postprocess.
    my $cmdfile = $base_bench_dir . "/pbench-run-benchmark.cmd";
    printf "cmdfile: %s\n", $cmdfile;
    open(my $cmd_fh, ">" . $cmdfile) ||
        die "Could not create $cmdfile";
    printf $cmd_fh "pbench-run-benchmark %s %s\n", $benchmark, join(" ", @ARGV);
}
my $es_dir = $base_bench_dir . "/es";
if ($pp_only) {
    # Do not re-use any existing CDM docs
    remove_tree($es_dir);
}
mkdir($es_dir);
for my $es_subdir (qw(run bench config metrics)) {
    mkdir($es_dir . "/" . $es_subdir);
}

# Use stockpile to collect configuration information
my @config_hosts = split(/,/, $params{"clients"});
if (-e "/tmp/stockpile") {
    print "Collecting confguration information with stockpile\n";
    stockpile_hosts(\@config_hosts, $base_bench_dir,"stockpile_output_path=".
                    $base_bench_dir . "/stockpile.json");
}

my $tool_group = $params{"tool-group"};
my $iteration_id = 0;
my $run_id = get_uuid;
my %last_run_doc;
print "Generating all benchmark iterations\n";
# We don't want these params passed to gen-iterations because they are not benchmark-native options
remove_params(\@ARGV, qw(postprocess-only user-desc user-tags user-name user-email pre-sample-cmd postprocess-mode postprocess-dir));
# First call pbench-gen-iterations and only resolve any --defaults=, so that the run
# doc has the full set of params
my $get_defs_cmd = "pbench-gen-iterations " . $benchmark . " --defaults-only " . join(" ", @ARGV);
# Escape any quotes so they don't get lost before calling pbench-gen-iterations
$get_defs_cmd =~ s/\"/\\\"/g;
print "resolving default first with $get_defs_cmd\n";
my @param_sets = `$get_defs_cmd 2>&1`;
my $rc = $? >> 8;
if ($rc != 0) {
    printf "%s\nCalling pbench-gen-iterations failed, exiting [rc=%d]\n", join(" ", @param_sets), $rc;
    exit 1;
}
my @iteration_names;
my %param_sets_common_params = find_common_parameters(@param_sets);

my $iterations_and_params_fh;
my $iterations_fh;

if (! $pp_only) {
    mkdir($base_bench_dir);
    open($iterations_and_params_fh, ">" . $base_bench_dir . "/iteration-list.txt");
    open($iterations_fh, ">" . $base_bench_dir . "/.iterations");

    sub signal_handler {
        interrupt_run($tool_group);
    }

    $SIG{INT} = "signal_handler";
    $SIG{QUIT} = "signal_handler";
    $SIG{TERM} = "signal_handler";

    # start tool meister ensuring benchmark, config, and date ENVs are presented so
    # that they are recorded by the Tool Data Sink in the metadata.log file.
    begin_run($base_bench_dir, $benchmark, $params{"user-tags"}, $date, $params{"sysinfo"}, $tool_group);
}

# There can be multiple parts of a run if the user generated multiple parameter-sets
# (used a "--" in their cmdline).  Each part of the run has it's own run document,
# but all of the run documents share the same run ID.
my $run_part = 0;
while (scalar @param_sets > 0) {
    my $nr_pp_jobs = 0;
    my $num_samples;
    my $param_set = shift(@param_sets);
    chomp $param_set;
    if ($param_set =~ /^#/) {
        printf "%s\n", $param_set;
        next;
    }
    # Process --samples= here, since it can be different for each parameter-set,
    # and we need this below for running pbench-run-benchmark-sample N times
    if ($param_set =~ s/--samples=(\S+)\s*//) {
        $num_samples = $1;
    } else {
        $num_samples = $defaults{'num-samples'};
    }
    my $get_iters_cmd = "pbench-gen-iterations " . $benchmark . " " . $param_set;
    # Escape quotes again as this will get passed to pbench-gen-iterations again.
    # We don't escape the quotes when writing to the run document (with $param_set)
    # because the conversion to JSON will do it for us.
    $get_iters_cmd =~ s/\"/\\\"/g;
    my @iterations = `$get_iters_cmd 2>&1`;
    $rc = $? >> 8;
    if ($rc != 0) {
        printf "%s\nCalling pbench-gen-iterations failed, exiting [rc=%d]\n", $get_iters_cmd, $rc;
        exit 1;
    }
    my %run_doc = create_run_doc($benchmark, $param_set, $params{"clients"}, $params{"servers"},
                    $params{"user-desc"}, $params{"user-tags"}, $params{"user-name"}, $params{"user-email"},
                    "pbench", ""); #todo: include tool names
    $run_doc{'run'}{'id'} = $run_id; # use the same run ID for all run docs
    # Now run the iterations for this parameter-set
    if ($pp_only) {
        # Prepare a bash script to process all iterations & samples at once
        # This provides for a *much* fatser post-processing on server-side
        open(BULK_FH, ">bulk-sample.sh");
        print BULK_FH "#!/bin/bash\n";
    }

    my %iterations_common_params = find_common_parameters(@iterations);

    my @iterations_labels;

    for my $iteration_params (@iterations) {
        $iteration_params =~ s/^\s+(.+)\s+$/$1/;

        my @split_params = split(/\s+/, $iteration_params);

        # create a label for the iteration, which becomes part of the
        # iteration name.  the label should be comprised of the
        # parameters that are not common across all iterations
        my $iteration_label = "";
        for my $param_piece (@split_params) {
            # if the param_piece does not exist in either of the
            # common parameters hashes then it should become part of
            # the iteration's label
            if (! exists($iterations_common_params{$param_piece}) ||
                ! exists($param_sets_common_params{$param_piece})) {
                $iteration_label .= $param_piece . " ";
            }
        }

        # strip off the -- from each parameter, remove beginning and
        # ending spaces, and convert spaces to underscores
        $iteration_label =~ s/\s*--/ /g;
        $iteration_label =~ s/\s+$//;
        $iteration_label =~ s/^\s+//;
        $iteration_label =~ s/\s/_/g;
        $iteration_label =~ s/\//:/g;

        # if the logic for determining a label for the iteration has
        # yielded an empty string just use the benchmark name -- this
        # is likely because there is a single iteration so all
        # parameters are common
        if (length($iteration_label) == 0) {
            $iteration_label = $benchmark;
        }

        push(@iterations_labels, $iteration_label);
    }

    if (! $pp_only) {
    	system("pbench-init-tools --group=" . $tool_group . " --dir=" . $base_bench_dir);
    }

    for (my $index=0; $index<@iterations; $index++) {
        my $iteration_params = $iterations[$index];
        my $iteration_label = $iterations_labels[$index];

        chomp $iteration_params;
        if ($iteration_params =~ /^#/) {
            printf "%s\n", $param_set;
            next;
        }
        my $iteration_name = $iteration_id . "__" . $iteration_label;
        push(@iteration_names, $iteration_name);
        my %iter_doc = create_bench_iter_doc(\%run_doc, $iteration_params,);
        if (! $pp_only) {
            put_json_file(\%iter_doc, $es_dir . "/bench/iteration-" . $iter_doc{'iteration'}{'id'} . ".json");
            metadata_log_record_iteration($base_bench_dir, $iteration_id, $iteration_params, $iteration_name);
            printf $iterations_fh "%d\n", $iteration_id;
            printf $iterations_and_params_fh "%d %s\n", $iteration_id, $iteration_params;
        }
        printf "\n\n\niteration_ID: %d\niteration_params: %s\n", $iteration_id, $iteration_params;
        my $iteration_dir = $base_bench_dir . "/" . $iteration_name;
        my @sample_dirs;
        if ($pp_only) {
            opendir(my $iter_dh, $iteration_dir) || die "Can't opendir $iteration_dir: $!";
            @sample_dirs = grep { /^sample\d+/ } readdir($iter_dh);
        } else {
            mkdir($iteration_dir);
            for (my $sample_id=0; $sample_id<$num_samples; $sample_id++) {
                $sample_dirs[$sample_id] = "sample" . $sample_id;
            }
        }
        while (scalar @sample_dirs > 0) {
            if (exists $params{'pre-sample-cmd'}) {
                my $pre_sample_cmd_output = `$params{'pre-sample-cmd'} 2>&1`;
                my $exit_code = $? >> 8;
                print "pre-sample-cmd output:\n$pre_sample_cmd_output";
                if ($exit_code != 0) {
                    printf "Stopping because of pre-sample-cmd exit code: %d\n", $exit_code;
                    exit 1;
                }
            }
            my $sample_dir = shift(@sample_dirs);
            print "$sample_dir\n";
            my $iteration_sample_dir = $iteration_dir . "/" . $sample_dir;
            if (! $pp_only) {
                mkdir($iteration_sample_dir);
            }
            my $last_sample = "0";
            if (scalar @sample_dirs == 0) {
                $last_sample = "1";
            }
            my $benchmark_cmd = "pbench-run-benchmark-sample " . $es_dir . "/bench/iteration-" .
                                $iter_doc{'iteration'}{'id'} . ".json " . $iteration_sample_dir .
                                " " . $base_bench_dir . " " . $tool_group .
                                " " . $last_sample . " " . $params{"postprocess-mode"} .
                                " " . $pp_only;
            if ($pp_only) {
                if ($params{'postprocess-mode'} eq 'html') {
                    # the last sample must be run by itself after all
                    # other samples are processed; other samples can
                    # be run in parallel
                    if ($last_sample eq "0") {
                        print BULK_FH "$benchmark_cmd &\n";
                    } elsif ($last_sample eq "1") {
                        print BULK_FH "echo Waiting for $nr_pp_jobs post-processing jobs to finish\n";
                        print BULK_FH "wait\n";
                        print BULK_FH "echo Post-processing last sample\n";
                        print BULK_FH "$benchmark_cmd\n";
                    }
                } else {
                    print BULK_FH "$benchmark_cmd &\n";
                }
                $nr_pp_jobs++;
            } else {
                open(CMD_FH, ">" . $iteration_sample_dir . "/benchmark-sample.cmd");
                printf CMD_FH "%s\n", $benchmark_cmd;
                close(CMD_FH);
                chmod(0755, $iteration_sample_dir . "/benchmark-sample.cmd");
                system($iteration_sample_dir . "/benchmark-sample.cmd");
                my $exit_code = $?;
                if ($exit_code != 0) {
                    printf "Stopping because of iteration-sample exit code: %d\n", $exit_code;
                    exit 1;
                }
            }
        }
        $iteration_id++;
    }
    if ($pp_only) {
        if ($params{'postprocess-mode'} eq 'cdm') {
            print BULK_FH "echo Waiting for $nr_pp_jobs post-processing jobs to finish\n";
            print BULK_FH "wait\n";
        }
        print BULK_FH "echo Sample processing complete!\n";
        close(BULK_FH);
        system(". ./bulk-sample.sh");
    } else {
        system("pbench-end-tools --group=" . $tool_group . " --dir=" . $base_bench_dir);
    }
    $run_doc{'run'}{'end'} = int time * 1000; # time in milliseconds
    put_json_file(\%run_doc, $es_dir . "/run/run" . $run_part . "-" . $run_doc{'run'}{'id'} . ".json");
    %last_run_doc = %run_doc; # We need to keep at least 1 run doc to create the config docs later
    $run_part++;
}

if (! $pp_only) {
    close $iterations_fh;
    close $iterations_and_params_fh;
    end_run($params{"sysinfo"}, $tool_group);
}

if ($params{'postprocess-mode'} eq 'html') {
    # Generate the result.html (to go away once CDM/Elastic UI is available)
    print "Running generate-benchmark-summary...";
    system(". " . $pbench_install_dir . "/base; " . $pbench_install_dir .
        "/bench-scripts/postprocess/generate-benchmark-summary " . $benchmark .
        " " . $benchmark . " " . $base_bench_dir);
    print "finished\n";
}

# Convert the stockpile data with scribe, then create CDM docs in ./es/config
if (-e $base_bench_dir . "/stockpile.json") {
    system('python3 -m venv /var/lib/pbench-agent/tmp/scribe && cd ' .
        $base_bench_dir . ' && scribe -t stockpile -ip ./stockpile.json >scribe.json');
    open(my $scribe_fh, "<" . $base_bench_dir . "/scribe.json") || die "Could not open " .
        $base_bench_dir . "/scribe.json";
    my $json_text = "";
    # Instead of 1 json document, there are actually multiple documents, but no separator
    # between them or organized in an array
    while (<$scribe_fh>) {
        $json_text .= $_;
        if (/^\}/) { # Assume this is the end of a json doc
            my %config_doc = create_config_doc(\%last_run_doc, from_json($json_text));
            if ($config_doc{'cdm'}{'doctype'} =~ /^config_(.+)/) {
                my $config_subname = $1;
                if (exists $config_doc{'config'}{'id'}) {
                    put_json_file(\%config_doc, $es_dir . "/config/" . $config_doc{'cdm'}{'doctype'} .
                                "-" . $config_doc{'config'}{'id'} . ".json");
                } else {
                    printf "Error: config doc's config.%s not found\n", $config_subname;
                }
            } else {
                printf "Error: config doc's cdm.doctype does not start with \"config_\"\n";
            }
            $json_text = "";
        }
    }
    close($scribe_fh);
}

printf "Run complete\n\n";
