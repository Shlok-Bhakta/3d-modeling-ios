# SPDX-FileCopyrightText: 2017-2023 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

if(WIN32 AND BUILD_MODE STREQUAL Debug)
  # zstandard is determined to build and link release mode libs in a debug
  # configuration, the only way to make it happy is to bend to its will
  # and give it a library to link with.
  set(
    PIP_CONFIGURE_COMMAND ${CMAKE_COMMAND} -E copy
    ${LIBDIR}/python/libs/python${PYTHON_SHORT_VERSION_NO_DOTS}_d.lib
    ${LIBDIR}/python/libs/python${PYTHON_SHORT_VERSION_NO_DOTS}.lib
  )
else()
  set(PIP_CONFIGURE_COMMAND echo ".")
endif()

set(PIP_CONSTRAINT_FILE ${BUILD_DIR}/constraints.txt)
# setuptools-scm is causing issues with their latest version
# issue: https://github.com/pypa/setuptools-scm/issues/1316
# but pinning it doesn't work since downstream package dependencies
# also seem to resolve the later versions
# we can alter this behaviour by using pip constraints
file(WRITE ${PIP_CONSTRAINT_FILE}
"setuptools-scm==${SETUPTOOLS_SCM_VERSION}\n"
)

set(_python_site_package_requirements
  setuptools==${SETUPTOOLS_VERSION}
  meson-python==${MESON_PYTHON_VERSION}
  packaging==${PACKAGING_VERSION}
  pyproject-metadata==${PYPROJECT_METADATA_VERSION}
  idna==${IDNA_VERSION}
  charset-normalizer==${CHARSET_NORMALIZER_VERSION}
  urllib3==${URLLIB3_VERSION}
  certifi==${CERTIFI_VERSION}
  requests==${REQUESTS_VERSION}
  autopep8==${AUTOPEP8_VERSION}
  pycodestyle==${PYCODESTYLE_VERSION}
  docutils==${DOCUTILS_VERSION}
  meson==${MESON_VERSION}
  attrs==${ATTRS_VERSION}
  cattrs==${CATTRS_VERSION}
  typing-extensions==${TYPING_EXTENSIONS_VERSION}
  tomli-w==${TOMLI_W_VERSION}
)

if(WITH_APPLE_CROSSPLATFORM)
  # iOS cannot execute its target interpreter during the dependency build.
  # Force platform-independent wheels and install them into the target standard
  # library. This also prevents the historical recipe from modifying the host
  # Python environment during a cross build.
  set(_python_target_site_packages
    ${LIBDIR}/python/lib/python${PYTHON_SHORT_VERSION}/site-packages
  )
  ExternalProject_Add(external_python_site_packages
    DOWNLOAD_COMMAND ""
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ""
    PREFIX ${BUILD_DIR}/site_packages
    INSTALL_COMMAND
      ${CMAKE_COMMAND} -E make_directory ${_python_target_site_packages}
      COMMAND ${CMAKE_COMMAND} -E env
        PIP_CONSTRAINT=${PIP_CONSTRAINT_FILE}
        ${PYTHON_BINARY} -m pip install
          --target ${_python_target_site_packages}
          --only-binary=:all:
          --platform any
          --implementation py
          --python-version ${PYTHON_SHORT_VERSION}
          --abi none
          --no-compile
          --cache-dir ${DOWNLOAD_DIR}/python-wheels
          --no-deps
          ${_python_site_package_requirements}
  )
  ExternalProject_Add_Step(external_python_site_packages harvest_ios
    COMMAND ${CMAKE_COMMAND} -E copy_directory
      ${_python_target_site_packages}
      ${HARVEST_TARGET}/python/lib/python${PYTHON_SHORT_VERSION}/site-packages
    DEPENDEES install
  )
else()
  ExternalProject_Add(external_python_site_packages
    DOWNLOAD_COMMAND ""
    CONFIGURE_COMMAND ${PIP_CONFIGURE_COMMAND}
    BUILD_COMMAND ""
    PREFIX ${BUILD_DIR}/site_packages

    # We do not build numpy, cython, or zstandard here as the pip builds are not reproducible.
    INSTALL_COMMAND
      ${CMAKE_COMMAND} -E env
        PIP_CONSTRAINT=${PIP_CONSTRAINT_FILE}
        ${PYTHON_BINARY} -m pip install --no-cache-dir ${SITE_PACKAGES_EXTRA}
        ${_python_site_package_requirements}
        --no-binary :all:
  )
endif()

unset(_python_site_package_requirements)
unset(_python_target_site_packages)

add_dependencies(
  external_python_site_packages
  external_python
)
