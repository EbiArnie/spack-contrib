# Copyright 2013-2023 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PerlDbi(PerlPackage):
    """Database independent interface for Perl"""

    homepage = "https://metacpan.org/pod/DBI"
    url = "https://cpan.metacpan.org/authors/id/T/TI/TIMB/DBI-1.643.tar.gz"

    maintainers("EbiArnie")

    version("1.643", sha256="8a2b993db560a2c373c174ee976a51027dd780ec766ae17620c20393d2e836fa")

    depends_on("perl@5.8.1:", type=("build", "link", "run", "test"))

    # FIXME: Add all non-perl dependencies and cross-check with the actual
    # package build mechanism (e.g. Makefile.PL)

    def configure_args(self):
        # FIXME: Add non-standard arguments
        # FIXME: If not needed delete this function
        args = []
        return args
