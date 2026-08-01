# IHateWeblogic – Oracle Forms & Reports Diagnostic Script Library

Author: Gunther Pipperr | https://pipperr.de
License: Apache 2.0

## Meaning of the Project Name


I – Innovation
H – Helps
A – Admins
T – To
E – Enhance
W – Weblogic
B – Based
L – Lifecycle
O – Operations
G – Governance
I – Integration
C – Control


Innovation Helps Admins To Enhance Weblogic-Based Lifecycle Operations, Governance, Integration & Control.



## Intention

Oracle Forms and Reports on WebLogic is powerful but notoriously difficult to diagnose.
This script library exists because the author has spent too many hours debugging obscure
configuration issues, font problems, segfaults, and SSL mismatches on Oracle Middleware
installations. It brings together knowledge from the author's blog (www.pipperr.de) and
years of documentation from real customer projects, built with the help of Claude to
turn personal experience into reusable automation and tooling.

This library focuses on:

- Installation and configuration of an Oracle WebLogic Forms/Reports and APEX setup behind Nginx
- Post-installation diagnosis
- Configuration validation (against Oracle documentation)
- Bug hunting and root cause analysis
- Documentation generation for support cases

## Target Environment

- Oracle Forms 14c / Reports 12c (technically 14c naming but Reports is still 12c codebase)
- Oracle WebLogic 14c (FMW 14.1.2)
- Oracle Linux 8 / 9

## Philosophy

- **Read-only by default.** Every script only reads and reports unless `--apply` is passed.
- **No surprises.** Every change is backed up before it is applied.
- **Source is king.** Where possible, behavior is validated against the official Oracle docs.
- **One library, many scripts.** All shared logic lives in `00-Setup/IHateWeblogic_lib.sh`.

## License

Copyright 2024 Gunther Pipperr – https://pipperr.de

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at:

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
