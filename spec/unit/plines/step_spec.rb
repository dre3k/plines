require 'spec_helper'
require 'plines'
require 'set'

module Plines
  describe Step do
    context 'when included' do
      it "adds the class to the pipeline's list of step classes" do
        mod = Module.new
        stub_const("MyPipeline", mod)
        mod.extend Plines::Pipeline

        MyPipeline.step_classes.should eq([])

        class MyPipeline::A
          include Plines::Step
        end

        class MyPipeline::B
          include Plines::Step
        end

        MyPipeline.step_classes.should eq([MyPipeline::A, MyPipeline::B])
      end

      it 'raises an error if it is not nested in a pipeline' do
        mod = Module.new
        stub_const("MyNonPipeline", mod)

        class MyNonPipeline::A; end

        expect { MyNonPipeline::A.send(:include, Plines::Step) }.to raise_error(/not nested in a pipeline module/)
      end
    end

    describe "#jobs_for" do
      it 'returns just 1 instance w/ the given data by default' do
        step_class(:A)
        instances = P::A.jobs_for(a: 1)
        instances.map(&:klass).should eq([P::A])
        instances.map(&:data).should eq([a: 1])
      end

      it 'returns one instance per array entry returned by the fan_out block' do
        step_class(:A) do
          fan_out do |data|
            [ { a: data[:a] + 1 }, { a: data[:a] + 2 } ]
          end
        end

        instances = P::A.jobs_for(a: 3)
        instances.map(&:klass).should eq([P::A, P::A])
        instances.map(&:data).should eq([{ a: 4 }, { a: 5 }])
      end
    end

    describe "#dependencies_for" do
      it "returns an empty array for a step with no declared dependencies" do
        step_class(:StepFoo)
        P::StepFoo.dependencies_for(:data).to_a.should eq([])
      end
    end

    describe "#has_no_dependencies?" do
      step_class(:StepA)

      it "returns true for steps that have no dependencies" do
        P::StepA.should have_no_dependencies
      end

      it "returns false for steps that have dependencies" do
        step_class(:StepC) { depends_on :StepA }
        P::StepC.should_not have_no_dependencies
      end
    end

    describe "#has_external_dependencies?" do
      it "returns true for a step class that has external dependencies" do
        step_class(:StepA) { has_external_dependency :foo }
        P::StepA.has_external_dependencies?.should be_true
      end

      it "returns false for a step class that lacks external dependencies" do
        step_class(:StepA)
        P::StepA.has_external_dependencies?.should be_false
      end
    end

    describe "#qless_queue" do
      it 'returns the default qless queue when it has no external dependencies' do
        step_class(:A)
        P::A.qless_queue.should be(P.default_queue)
      end

      it 'returns the awaiting_external_dependency_queue when it has external dependencies' do
        step_class(:A) { has_external_dependency :foo }
        P::A.qless_queue.should be(P.awaiting_external_dependency_queue)
      end
    end

    describe "#depends_on" do
      step_class(:StepA)
      step_class(:StepB)

      it "adds dependencies based on the given class name" do
        step_class(:StepC) do
          depends_on :StepA, :StepB
        end

        dependencies = P::StepC.dependencies_for({ a: 1 })
        dependencies.map(&:klass).should eq([P::StepA, P::StepB])
        dependencies.map(&:data).should eq([{ a: 1 }, { a: 1 }])
      end

      it "resolves step class names in the enclosing module" do
        pipeline = Module.new do
          extend Plines::Pipeline
        end
        stub_const("MySteps", pipeline)

        class MySteps::A
          include Plines::Step
        end

        class MySteps::B
          include Plines::Step
          depends_on :A
        end

        dependencies = MySteps::B.dependencies_for({})
        dependencies.map(&:klass).should eq([MySteps::A])
      end

      context 'when depending on a fan_out step' do
        step_class(:StepX) do
          fan_out do |data|
            [1, 2, 3].map { |v| { a: data[:a] + v } }
          end
        end

        it "depends on all of the step instances of the named type when it fans out into multiple instances" do
          step_class(:StepY) do
            depends_on :StepX
          end

          dependencies = P::StepY.dependencies_for(a: 17)
          dependencies.map(&:klass).should eq([P::StepX, P::StepX, P::StepX])
          dependencies.map(&:data).should eq([{ a: 18 }, { a: 19 }, { a: 20 }])
        end

        it "depends on the the subset of instances for which the block returns true when given a block" do
          step_class(:StepY) do
            depends_on(:StepX) { |d| d[:a].even? }
          end

          dependencies = P::StepY.dependencies_for(a: 17)
          dependencies.map(&:klass).should eq([P::StepX, P::StepX])
          dependencies.map(&:data).should eq([{ a: 18 }, { a: 20 }])
        end
      end

      describe "#perform", :redis do
        let(:qless_job) { fire_double("Qless::Job", jid: "my-jid", data: { "foo" => "bar", "_job_batch_id" => job_batch.id }) }
        let(:job_batch) { JobBatch.new(pipeline_module, "abc:1") }

        before { job_batch.pending_job_jids << qless_job.jid }

        it "creates an instance and calls #perform, with the job data available as a DynamicStruct from an instance method" do
          foo = nil
          step_class(:A) do
            define_method(:perform) do
              foo = job_data.foo
            end
          end

          P::A.perform(qless_job)
          foo.should eq("bar")
        end

        it "makes the job_batch available in the perform instance method" do
          j_batch = data_hash = nil
          step_class(:A) do
            define_method(:perform) do
              j_batch = self.job_batch
              data_hash = job_data.to_hash
            end
          end

          P::A.perform(qless_job)
          j_batch.should eq(job_batch)
          data_hash.should_not have_key("_job_batch_id")
        end

        it "marks the job as complete in the job batch" do
          job_batch.pending_job_jids.should include(qless_job.jid)
          job_batch.completed_job_jids.should_not include(qless_job.jid)

          step_class(:A) do
            def perform; end
          end

          P::A.perform(qless_job)
          job_batch.pending_job_jids.should_not include(qless_job.jid)
          job_batch.completed_job_jids.should include(qless_job.jid)
        end

        it "supports #around_perform middleware modules" do
          step_class(:A) do
            def self.order
              @order ||= []
            end

            include Module.new {
              def around_perform
                self.class.order << :before_1
                super { yield }
                self.class.order << :after_1
              end
            }

            include Module.new {
              def around_perform
                self.class.order << :before_2
                super { yield }
                self.class.order << :after_2
              end
            }

            define_method(:perform) { self.class.order << :perform }
          end

          P::A.perform(qless_job)
          P::A.order.should eq([:before_2, :before_1, :perform, :after_1, :after_2])
        end
      end
    end
  end
end

