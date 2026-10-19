#!/usr/bin/env perl
# Copyright (C) 2026 Data Sculpting Inc.
# SPDX-License-Identifier: GPL-3.0-only
# Additional notice/origin terms: see ADDITIONAL_TERMS.md (GPLv3 Section 7).
# Distributed under GNU GPL version 3, without warranty. See LICENSE.
use strict;
use warnings;
# Resolve sibling modules from the script location so launching from another
# working directory does not change configuration or asset locations.
use FindBin qw($RealBin);
use lib "$RealBin/lib";
use VisLlama::Proxy ();

exit VisLlama::Proxy::run();
