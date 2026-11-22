"""The line prefixes a promotion step writes for its failure, which the issue filer reads.

A leaf module: it imports nothing, so the issue filer (report_issue.py, which
failure_cause.py loads in every infra retry) does not load the selector.
"""

# The line prefixes the issue filer attaches to a failure (report_issue.py reads all three).
BISECT_PREFIX = "Promotion bisect: "
EXCERPT_PREFIX = "Promotion excerpt: "
SUSPECT_PREFIX = "Promotion suspects: "
