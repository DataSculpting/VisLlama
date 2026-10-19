# Copyright (C) 2026 Data Sculpting Inc.
# SPDX-License-Identifier: GPL-3.0-only
# Additional notice/origin terms: see ADDITIONAL_TERMS.md (GPLv3 Section 7).
# Distributed under GNU GPL version 3, without warranty. See LICENSE.
package VisLlama::Context;

# Shared configuration and managed process state for one control process.
# This module defines values only; imports must not start services or write files.
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw($APP_VERSION %CFG $STATE);

# One process-wide state owner. Importing this module does not read or write files.
our $APP_VERSION = '1.5.12';

our %CFG = (
    listen_host => '127.0.0.1',
    listen_port => 9090,
    model_root  => '',
    discovery_root => '',
    builds      => {},
    build_order => [],
);

our $STATE = {
    proc     => undef,
    pid      => undef,
    started  => undef,
    command  => undef,
    log_file => undef,
    log_clear_offset => 0,
    exit_code_file => undef,
    build    => undef,
    model    => undef,
    last_exit_code => undef,
    last_exit_time => undef,
    last_error => undef,
    crashed => 0,
    stop_requested => 0,
    mode => 'single',
    router_host => undef,
    router_port => undef,
    router_internal_port => undef,
    router_engines => {},
    router_route_map => undef,
    proxy_proc => undef,
    proxy_pid => undef,
    proxy_log => undef,
    proxy_launcher => undef,
};

1;
