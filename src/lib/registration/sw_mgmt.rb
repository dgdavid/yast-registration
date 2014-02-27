# encoding: utf-8

# ------------------------------------------------------------------------------
# Copyright (c) 2014 Novell, Inc. All Rights Reserved.
#
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program; if not, contact Novell, Inc.
#
# To contact Novell about this file by physical or electronic mail, you may find
# current contact information at www.novell.com.
# ------------------------------------------------------------------------------
#
#

require "yast"

require "tmpdir"
require "fileutils"

require "registration/exceptions"

module Registration
  Yast.import "Mode"
  Yast.import "Pkg"
  Yast.import "Installation"
  Yast.import "PackageCallbacksInit"
  Yast.import "Progress"

  class SwMgmt
    include Yast
    include Yast::Logger
    extend Yast::I18n

    textdomain "registration"

    ZYPP_DIR = "/etc/zypp"

    def self.init
      # display progress when refreshing repositories
      PackageCallbacksInit.InitPackageCallbacks
      Pkg.TargetInitialize(Installation.destdir)
      Pkg.TargetLoad
      Pkg.SourceStartManager(true)
    end

    def self.save
      Pkg.SourceSaveAll
    end

    # during installation /etc/zypp directory is not writable (mounted on
    # a read-only file system), the workaround is to copy the whole directory
    # structure into a writable temporary directory and override the original
    # location by "mount -o bind"
    def self.ensure_zypp_config_writable
      if Mode.installation && !File.writable?(ZYPP_DIR)
        log.info "Copying libzypp config to a writable place"

        # create writable zypp directory structure in /tmp
        tmpdir = Dir.mktmpdir

        log.info "Copying #{ZYPP_DIR} to #{tmpdir} ..."
        ::FileUtils.cp_r ZYPP_DIR, tmpdir

        log.info "Mounting #{tmpdir} to #{ZYPP_DIR}"
        `mount -o bind #{tmpdir}/zypp #{ZYPP_DIR}`
      end
    end

    def self.products_to_register
      # just for debugging:
      # return [{"name" => "SUSE_SLES", "arch" => "x86_64", "version" => "12-"}]

      # during installation the products are :selected,
      # on a running system the products are :installed
      selected_base_products = Pkg.ResolvableProperties("", :product, "").find_all do |p|
        p["status"] == :selected || p["status"] == :installed
      end

      # filter out not needed data
      product_info = selected_base_products.map{|p| { "name" => p["name"], "arch" => p["arch"], "version" => p["version"]}}

      log.info("Products to register: #{product_info}")

      product_info
    end

    # add the services to libzypp and load (refresh) them
    def self.add_services(product_services, credentials)
      # save repositories before refreshing added services (otherwise
      # pkg-bindings will treat them as removed by the service refresh and
      # unload them)
      if !Pkg.SourceSaveAll
        # error message
        raise Registration::PkgError, N_("Saving repository configuration failed.")
      end

      # each registered product
      product_services.each do |product_service|
        # services for the each product
        product_service.services.each do |service|
          log.info "Adding service #{service.name.inspect} (#{service.url})"

          # progress bar label
          Progress.Title(_("Adding service %s...") % service.name)

          # TODO FIXME: SCC currenly does not return credentials for the service,
          # just reuse the global credentials and save to a different file
          credentials.file = service.name + "_credentials"
          credentials.write

          if !Pkg.ServiceAdd(service.name, service.url.to_s)
            # error message
            raise Registration::PkgError, N_("Adding the service failed.")
          end
          # refresh works only for saved services
          if !Pkg.ServiceSave(service.name)
            # error message
            raise Registration::PkgError, N_("Saving the new service failed.")
          end

          if !Pkg.ServiceRefresh(service.name)
            # error message
            raise Registration::PkgError, N_("The service refresh has failed.")
          end

          Progress.NextStep
        end
      end
    end

  end
end

