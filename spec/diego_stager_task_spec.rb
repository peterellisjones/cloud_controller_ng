require "spec_helper"

module VCAP::CloudController
  describe DiegoStagerTask do
    let(:message_bus) { CfMessageBus::MockMessageBus.new }
    let(:staging_timeout) { 360 }
    let(:environment_json) { {} }
    let(:app) do
      AppFactory.make(:package_hash  => "abc",
                      :name => "app-name",
                      :droplet_hash  => "I DO NOTHING",
                      :package_state => "PENDING",
                      :state         => "STARTED",
                      :instances     => 1,
                      :memory => 259,
                      :disk_quota => 799,
                      :file_descriptors => 1234,
                      :environment_json => environment_json
      )
    end
    let(:blobstore_url_generator) { double("fake url generator") }
    let(:completion_callback) { lambda {|x| return x } }

    let(:app_package_download_url) { "http://app-package.com" }
    let(:admin_buildpack_download_url) { "http://admin-buildpack.com" }
    let(:build_artifacts_cache_download_uri) { "http://buildpack-artifacts-cache.com" }

    before do
      Buildpack.create(name: "java", key: "java-buildpack-guid", position: 1)
      Buildpack.create(name: "ruby", key: "ruby-buildpack-guid", position: 2)

      allow(blobstore_url_generator).to receive(:app_package_download_url).and_return(app_package_download_url)
      allow(blobstore_url_generator).to receive(:admin_buildpack_download_url).and_return(admin_buildpack_download_url)
      allow(blobstore_url_generator).to receive(:buildpack_cache_download_url).and_return(build_artifacts_cache_download_uri)

      EM.stub(:add_timer)
      EM.stub(:defer).and_yield
    end

    let(:diego_stager_task) { DiegoStagerTask.new(staging_timeout, message_bus, app, blobstore_url_generator) }

    describe '#stage' do
      let(:logger) { FakeLogger.new([]) }

      before do
        Steno.stub(:logger).and_return(logger)
      end

      def perform_stage
        diego_stager_task.stage(&completion_callback)
      end

      it 'assigns a new staging_task_id to the app being staged' do
        perform_stage
        app.staging_task_id.should_not be_nil
        app.staging_task_id.should == diego_stager_task.task_id
      end

      it 'logs the beginning of staging' do
        logger.should_receive(:info).with('staging.begin', { app_guid: app.guid })
        perform_stage
      end

      it 'publishes the diego.staging.start message' do
        perform_stage
        expect(message_bus.published_messages.first).
            to include(subject: "diego.staging.start", message: diego_stager_task.staging_request)
      end

      it 'the diego.staging.start message includes a stack' do
        perform_stage
        expect(message_bus.published_messages.first[:message]).
            to include(
                   stack: app.stack.name
               )
      end
    end

    describe "staging_request" do
      let(:environment_json) {  { "USER_DEFINED" => "OK" } }
      let(:domain) {  PrivateDomain.make :owning_organization => app.space.organization }
      let(:route) { Route.make(:domain => domain, :space => app.space) }

      let(:service_instance_one) do
        service = Service.make(:label => "elephant-label", :requires => ["syslog_drain"])
        service_plan = ServicePlan.make(:service => service)
        ManagedServiceInstance.make(:space => app.space, :service_plan => service_plan, :name => "elephant-name")
      end

      let(:service_instance_two) do
        service = Service.make(:label => "giraffesql-label")
        service_plan = ServicePlan.make(:service => service)
        ManagedServiceInstance.make(:space => app.space, :service_plan => service_plan, :name => "giraffesql-name")
      end

      let!(:service_binding_one) do
        ServiceBinding.make(:app => app, :service_instance => service_instance_one, :syslog_drain_url => "syslog_drain_url-syslog-url")
      end

      let!(:service_binding_two) do
        ServiceBinding.make(
            :app => app,
            :service_instance => service_instance_two,
            :credentials => {"uri" => "mysql://giraffes.rock"})
      end

      before do
        app.add_route(route)
      end

      describe "limits" do
        it "limits memory" do
          expect(diego_stager_task.staging_request[:memory_mb]).to eq(259)
        end
        it "limits disk" do
          expect(diego_stager_task.staging_request[:disk_mb]).to eq(799)
        end
        it "limits file descriptors" do
          expect(diego_stager_task.staging_request[:file_descriptors]).to eq(1234)
        end
      end

      describe "buildpacks" do
        context "when the app has a GitBasedBuildpack" do
          context "when the GitBasedBuildpack uri begins with http(s)://" do
            before do
              app.buildpack = "http://github.com/mybuildpack/bp.zip"
            end

            it "should use the GitBasedBuildpack's uri and name it 'custom', and use the url as the key" do
              expect(diego_stager_task.staging_request[:buildpacks]).to eq([{name: "custom", key: "http://github.com/mybuildpack/bp.zip", url: "http://github.com/mybuildpack/bp.zip"}])
            end
          end

          context "when the GitBasedBuildpack uri begins with git://" do
            before do
              app.buildpack = "git://github.com/mybuildpack/bp"
            end

            it "should use the list of admin buildpacks" do
              expect(diego_stager_task.staging_request[:buildpacks]).to eq([
                    {name: "java", key: "java-buildpack-guid", url: admin_buildpack_download_url},
                    {name: "ruby", key: "ruby-buildpack-guid", url: admin_buildpack_download_url},
              ])
            end
          end

          context "when the GitBasedBuildpack uri ends with .git" do
            before do
              app.buildpack = "https://github.com/mybuildpack/bp.git"
            end

            it "should use the list of admin buildpacks" do
              expect(diego_stager_task.staging_request[:buildpacks]).to eq([
                                                                               {name: "java", key: "java-buildpack-guid", url: admin_buildpack_download_url},
                                                                               {name: "ruby", key: "ruby-buildpack-guid", url: admin_buildpack_download_url},
                                                                           ])
            end
          end
        end

        context "when the app has a named buildpack" do
          before do
            app.buildpack = "java"
          end

          it "should use that buildpack" do
            expect(diego_stager_task.staging_request[:buildpacks]).to eq([
                {name: "java", key: "java-buildpack-guid", url: admin_buildpack_download_url},
            ])

          end
        end

        context "when the app has no buildpack specified" do
          it "should use the list of admin buildpacks" do
            expect(diego_stager_task.staging_request[:buildpacks]).to eq([
                 {name: "java", key: "java-buildpack-guid", url: admin_buildpack_download_url},
                 {name: "ruby", key: "ruby-buildpack-guid", url: admin_buildpack_download_url},
            ])
          end
        end
      end

      describe "environment" do
        it "contains user defined environment variables" do
          expect(diego_stager_task.staging_request[:environment].last).to eq({key:"USER_DEFINED", value:"OK"})
        end

        it "contains VCAP_APPLICATION from application" do
          expect(app.vcap_application).to be
          expect(
            diego_stager_task.staging_request[:environment]
          ).to include({key:"VCAP_APPLICATION", value:app.vcap_application.to_json})
        end

        it "contains VCAP_SERVICES" do
          elephant_label = service_instance_one.service.label + "-" + service_instance_one.service.version
          giraffe_label = service_instance_two.service.label + "-" + service_instance_two.service.version
          expected_hash = {
            elephant_label => [{
              "name" => service_instance_one.name,
              "label" => elephant_label,
              "tags" => service_instance_one.tags,
              "plan" => service_instance_one.service_plan.name,
              "credentials" => service_binding_one.credentials,
              "syslog_drain_url" => "syslog_drain_url-syslog-url"
            }],

            giraffe_label => [{
              "name" => service_instance_two.name,
              "label" => giraffe_label,
              "tags" => service_instance_two.tags,
              "plan" => service_instance_two.service_plan.name,
              "credentials" => service_binding_two.credentials,
            }]
          }
          expect(
            diego_stager_task.staging_request[:environment]
          ).to include({key:"VCAP_SERVICES", value:expected_hash.to_json})
        end

        it "contains DATABASE_URL" do
          expect(
            diego_stager_task.staging_request[:environment]
          ).to include({key:"DATABASE_URL", value:"mysql2://giraffes.rock"})
        end

        it "contains MEMORY_LIMIT" do
          expect(
            diego_stager_task.staging_request[:environment]
          ).to include({key:"MEMORY_LIMIT", value:"259m"})
        end

        it "contains app build artifact cache download uri" do
          expect(blobstore_url_generator).to receive(:buildpack_cache_download_url).with(app).and_return(build_artifacts_cache_download_uri)
          staging_request = diego_stager_task.staging_request
          expect(staging_request[:build_artifacts_cache_download_uri]).to eq(build_artifacts_cache_download_uri)
        end

        it "contains app bits download uri" do
          expect(blobstore_url_generator).to receive(:app_package_download_url).with(app).and_return(app_package_download_url)
          expect(diego_stager_task.staging_request[:app_bits_download_uri]).to eq(app_package_download_url)
        end
      end
    end
  end
end
