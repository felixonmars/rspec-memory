# Copyright, 2017, by Samuel G. D. Williams. <http://www.codeotaku.com>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

require 'objspace'

module RSpec
	module Memory
		Allocation = Struct.new(:count, :size) do
			SLOT_SIZE = ObjectSpace.memsize_of(Object.new)
			
			def << object
				self.count += 1
				
				# We don't want to force specs to take the slot size into account.
				self.size += ObjectSpace.memsize_of(object) - SLOT_SIZE
			end
			
			def self.default_hash
				Hash.new{|h,k| h[k] = Allocation.new(0, 0)}
			end
		end
		
		class Trace
			def self.supported?
				# There are issues on truffleruby-1.0.0rc9
				return false if RUBY_ENGINE == "truffleruby"
				
				ObjectSpace.respond_to?(:trace_object_allocations)
			end
			
			if supported?
				def self.capture(*args, &block)
					self.new(*args).tap do |trace|
						trace.capture(&block)
					end
				end
			else
				def self.capture(*args, &block)
					yield
					
					return nil
				end
			end
			
			def initialize(klasses)
				@klasses = klasses
				
				@allocated = Allocation.default_hash
				@retained = Allocation.default_hash
				
				@ignored = Allocation.default_hash
				
				@total = Allocation.new(0, 0)
			end
			
			attr :allocated
			attr :retained
			
			attr :ignored
			
			attr :total
			
			def current_objects(generation)
				allocations = []
				
				ObjectSpace.each_object do |object|
					if ObjectSpace.allocation_generation(object) == generation
						allocations << object
					end
				end
				
				return allocations
			end
			
			def find_base(object)
				@klasses.find{|klass| object.is_a? klass}
			end
			
			def capture(&block)
				GC.start
				
				begin
					GC.disable
					
					generation = GC.count
					ObjectSpace.trace_object_allocations(&block)
					
					allocated = current_objects(generation)
				ensure
					GC.enable
				end
				
				GC.start
				retained = current_objects(generation)
				
				# All allocated objects, including those freed in the last GC:
				allocated.each do |object|
					if klass = find_base(object)
						@allocated[klass] << object
					else
						# If the user specified classes, but we can't pin this allocation to a specific class, we issue a warning.
						if @klasses.any?
							warn "Ignoring allocation of #{object.class} at #{ObjectSpace.allocation_sourcefile(object)}:#{ObjectSpace.allocation_sourceline(object)}"
						end
						
						@ignored[object.class] << object
					end
					
					@total << object
				end
				
				# Retained objects are still alive after a final GC:
				retained.each do |object|
					if klass = find_base(object)
						@retained[klass] << object
					end
				end
			end
		end
	end
end
