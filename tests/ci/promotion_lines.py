"""The line prefixes a promotion step writes for its failure, which the issue filer reads.

A leaf module: it imports nothing, so the issue filer (report_issue.py, which
failure_cause.py loads in every infra retry) does not load the selector.
"""

# The line prefixes the issue filer attaches to a failure (report_issue.py reads both).
BISECT_PREFIX = "Promotion bisect: "
SUSPECT_PREFIX = "Promotion suspects: "
