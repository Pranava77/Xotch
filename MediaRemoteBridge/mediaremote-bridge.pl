#!/usr/bin/perl
# Loads MediaRemoteBridge.dylib into this Apple-signed perl process and runs it.
# See MediaRemoteBridge.m for why.
use strict;
use warnings;
use DynaLoader;

my $library = shift or die "usage: mediaremote-bridge.pl <MediaRemoteBridge.dylib>\n";
my $handle = DynaLoader::dl_load_file($library, 0)
    or die "couldn't load $library: " . DynaLoader::dl_error() . "\n";
my $symbol = DynaLoader::dl_find_symbol($handle, "XotchMediaRemoteRun")
    or die "XotchMediaRemoteRun not found: " . DynaLoader::dl_error() . "\n";
DynaLoader::dl_install_xsub("main::run_bridge", $symbol);
run_bridge();
