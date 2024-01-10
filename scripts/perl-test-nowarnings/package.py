# Copyright 2013-2023 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PerlTestNowarnings(PerlPackage):
    """Make sure you didn't emit any warnings while testing"""

    homepage = "https://metacpan.org/pod/Test::NoWarnings"
    url = "https://cpan.metacpan.org/authors/id/H/HA/HAARG/Test-NoWarnings-1.06.tar.gz"

    maintainers("EbiArnie")

    version("1.06", sha256="c2dc51143b7eb63231210e27df20d2c8393772e0a333547ec8b7a205ed62f737")

    depends_on("perl@5.6.0:", type=("build", "link", "run", "test"))

    # FIXME: Add all non-perl dependencies and cross-check with the actual
    # package build mechanism (e.g. Makefile.PL)

    def configure_args(self):
        # FIXME: Add non-standard arguments
        # FIXME: If not needed delete this function
        args = []
        return args
