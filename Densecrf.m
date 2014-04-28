% Solves densecrf problem described in:
%
% Philipp Krähenbühl and Vladlen Koltun
% Efficient Inference in Fully Connected CRFs with Gaussian Edge Potentials
% NIPS 2011 
%
% 1. Solvers
%   a) meanfield 			 : Krähenbühls' meanfield implementation
%   b) meanfield_matlab: Very slow but non approximate meanfield implementation.
%		c) threshold       : Returns threhold solution of the unary cost
%   d) trws						 : Tree-reweighted message passing algorithm.  
%
% Remarks:
% The energy reported is calculate via approximate filtering and is approximate.
% Furthermore the potts cost is -[x==y] instead of the usual +[x!=y],
% adding more regularization may result in lower energy.
% Exact energy may be calculate via the exact_energy method
%
% WARNING: 
% If NormalizationType is changed the problem meanfield solves is 
% redefined and the other solvers solves a different problem.
%
classdef Densecrf < handle
	% Settings
	properties		
		gaussian_x_stddev = 3;
		gaussian_y_stddev = 3;
		gaussian_weight = 1; 

		bilateral_x_stddev = 60;
		bilateral_y_stddev = 60;
		bilateral_r_stddev = 10;
		bilateral_g_stddev = 10;
		bilateral_b_stddev = 10;
		bilateral_weight = 1; 
		
		debug = false;
		iterations = 100;
		
		% Used for TRWS solver, pairwise cost which are lower then this are not added to the cost function.
		% For larger images this can be used to limit the memory usage. 
		% The energy will not be correct but the lower bound will still be valid.
		min_pairwise_cost = 0;
	
		segmentation = [];

		% Only used for meanfield solver
		%	NO_NORMALIZATION,    // No normalization whatsoever (will lead to a substantial approximation error)
		% NORMALIZE_BEFORE,    // Normalize before filtering (Not used, just there for completeness)
	  % NORMALIZE_AFTER,     // Normalize after filtering (original normalization in NIPS 11 work)
		% NORMALIZE_SYMMETRIC, // Normalize before and after (ICML 2013, low approximation error and preserves the symmetry of CRF)
		NormalizationType = 'NO_NORMALIZATION';

		% Virtual
		im;
		unary;

		solver = '';
	end
	
	properties (SetAccess = protected)
		im_stacked;
		unary_stacked;
		
		energy = nan;
	end
	
	properties (Hidden)
		image_size;
		get_energy = true;
	end
	
	methods (Static)
		% Restack 3D matrix s.t
		% x0y0z0 x0y0z1 , .... x1y0z0,x1y0z1
		function out = color_stack(in)	
			assert(ndims(in) == 3);
			out = zeros(numel(in),1);
			
			colors = size(in,3);
			
			for c = 1:colors
				out(c:colors:end) = reshape(in(:,:,c),[],1);
			end
		end
	
		% Inverse of colorstack
		function out = inverse_color_stack(in, image_size)
			assert(isvector(in));
			colors = image_size(3);
			
			assert(mod(numel(in),colors) == 0);
			assert(numel(image_size) == 3);
			
			out = zeros(image_size);
			for c = 1:colors
				out(:,:,c) = reshape(in(c:colors:end),image_size(1:2));
			end
		end
		
		
	end
		
	methods
		% Gather and format
		function settings = gather_settings(self)

			settings.gaussian_x_stddev = self.gaussian_x_stddev;
			settings.gaussian_y_stddev = self.gaussian_y_stddev;
			settings.gaussian_weight =  self.gaussian_weight;
			
			settings.bilateral_x_stddev = self.bilateral_x_stddev;
			settings.bilateral_y_stddev = self.bilateral_y_stddev;
			settings.bilateral_r_stddev = self.bilateral_r_stddev;
			settings.bilateral_g_stddev = self.bilateral_g_stddev;
			settings.bilateral_b_stddev = self.bilateral_b_stddev;
			settings.bilateral_weight = self.bilateral_weight;
			settings.min_pairwise_cost = self.min_pairwise_cost;
			settings.NormalizationType = self.NormalizationType;

			settings.debug = logical(self.debug);
			settings.iterations = int32(self.iterations);
		end
		
		function self =  Densecrf(im, unary)
			addpath([fileparts(mfilename('fullpath')) filesep 'include']);
			
			% Force to correct form
			if ~isa(im,'uint8')
				warning('Image is not unsgined 8 bit int, converting.');
			end
			
			if ~isa(unary,'single');
				warning( 'Unary cost must be float/single, converting.');
			end
			
			self.image_size = uint32(size(im));
			assert(numel(self.image_size) == 3);
			
			self.im = im;
			self.unary = unary;
	
			self.get_energy = false;
			self.segmentation = ones(self.image_size(1:2));
			self.get_energy = true;

		end

		% Compile if need be
		function compile(~, file_name)
			my_name = mfilename('fullpath');
			my_path = [fileparts(my_name) filesep];
			eigen_path = [my_path 'include' filesep 'densecrf' filesep 'include' filesep];
			lbfgs_include_path = [my_path 'include' filesep 'densecrf' filesep 'external' filesep 'liblbfgs' filesep  'include' filesep];

			cpp_file = [file_name '_mex.cpp'];
			out_file = [file_name '_mex'];
			
			extra_arguments = {};
			extra_arguments{end+1} = ['-I' my_path];
			extra_arguments{end+1} = ['-I' eigen_path];
			extra_arguments{end+1} = ['-I' lbfgs_include_path];
			extra_arguments{end+1} = ['-lgomp'];
			
			% Additional files to be compiled.
			mf_dir = ['densecrf' filesep 'src' filesep];
			trws_dir =  ['TRW_S-v1.3' filesep];
			lbfgs_dir = ['densecrf' filesep 'external'  filesep 'liblbfgs' filesep 'lib' filesep];
			sources = {[mf_dir 'util.cpp'], ...
				[mf_dir 'densecrf.cpp'], ...
				[mf_dir 'labelcompatibility.cpp'], ...
				[mf_dir 'objective.cpp'], ...
				[mf_dir 'optimization.cpp'], ...
				[mf_dir 'pairwise.cpp'], ...
				[mf_dir 'permutohedral.cpp'], ...
				[mf_dir 'unary.cpp'], ...
				[lbfgs_dir 'lbfgs.cpp'], ...
				[trws_dir 'minimize.cpp'], ...
				[trws_dir 'MRFEnergy.cpp' ], ...
				[trws_dir 'ordering.cpp'], ...
				[trws_dir 'treeProbabilities.cpp' ]};
			% Only compile if files have changed
			compile(cpp_file, out_file, sources, extra_arguments)
		end
		
		function segmentation = matlab_meanfield(self)
			settings = self.gather_settings;
			segmentation = matlab_meanfield(double(self.unary), double(self.im), settings);

			self.segmentation = segmentation;
			self.solver = 'matlab meanfield';
		end

		function segmentation = threshold(self)
			[~,segmentation] = min(self.unary,[],3);
			self.segmentation = segmentation;
			self.solver = 'threshold';
		end
		
		function segmentation = meanfield(self)
			settings = self.gather_settings;
			settings.solver = 'MF';
			self.compile('densecrf');
			
			[segmentation, energy, bound] =  densecrf_mex(self.im_stacked, self.unary_stacked, self.image_size, settings);
			
			segmentation = segmentation+1;

			tmp = self.get_energy;
			self.get_energy = false;
			self.segmentation = segmentation;
			self.get_energy = tmp;

			self.energy = energy;
			self.solver = 'meanfield';
		end
		
		function [segmentation, energy, bound] = trws(self)
			settings = self.gather_settings;
			settings.solver = 'TRWS';
			self.compile('densecrf');
			
			[segmentation, energy, lower_bound] =  densecrf_mex(self.im_stacked, self.unary_stacked, self.image_size, settings);
			
			segmentation = segmentation+1;
			self.segmentation = segmentation;
			self.solver = 'trws';
		end
		
		% Calculate exact energy of current solution
		function calculate_energy(self)
			self.compile('energy');
			settings = self.gather_settings;
			segmentation = int16(self.segmentation - 1);

			[~, energy] =  energy_mex(self.im_stacked, self.unary_stacked, self.image_size, segmentation, settings);
			self.energy = energy;
		end

		% Calculate exact energy by summing of all pairs (this is very slow)
		function [exact_energy, mf_energy] = calculate_exact_energy(self)
			self.compile('energy');
			settings = self.gather_settings;
			settings.calculate_exact_energy = true;

			segmentation = int16(self.segmentation - 1);
			[exact_energy, mf_energy] =  energy_mex(self.im_stacked, self.unary_stacked, self.image_size, segmentation, settings);
			self.energy = mf_energy;
		end

		
		function display(self)		
			subplot(1,2,1)
			imshow(double(self.im)/256)
			title('Image');

			if (~isempty(self.segmentation))
				subplot(1,2,2);
				imagesc(self.segmentation);
				axis equal; axis off;
				title(sprintf('\n Energy: %g. \n Solver: %s', ...
										 self.energy, self.solver));
			end
		
			details(self);
		end

		function num_labels = num_labels(self)
			num_labels = size(self.unary,3);
		end

		% Generate a random solution.
		function random_solution(self, seed)
			if nargin == 2
				rng(seed)
			end
				
			self.segmentation = ceil(rand(self.image_size(1:2))*self.num_labels());
		end

		% set/get methods
		function set.im(self, im)
			self.im = im;
			
			% Stacking s.t. colors is contiguous in memory
			self.im_stacked = uint8(Densecrf.color_stack(im));
		end

		function set.unary(self, unary)
			self.unary = unary;
			self.unary_stacked = single(Densecrf.color_stack(unary));
		end
		
		function set.segmentation(self, segmentation)

			if ~all( size(segmentation) ==  self.image_size(1:2))
				error('Segmentation must be of same size as image.');
			end

			if min(segmentation(:) < 1)
				error('Segmentation entries should be 1,...,num labels.');
			end

			if max(segmentation(:) > size(self.unary,3))
				error('Segmentation entries should be 1,...,num labels.');
			end		

			if (norm(round(segmentation(:)) - segmentation(:)) > 0)
				error('Segmentation entries must be integers.');
			end

			self.segmentation = segmentation;
			
			if (self.get_energy)
				self.calculate_energy();
			else
				self.energy = nan;
			end

			self.solver = '';
		end
		
		function set.NormalizationType(self, NormalizationType)

			ok_values = {'NO_NORMALIZATION','NORMALIZE_BEFORE','NORMALIZE_AFTER','NORMALIZE_SYMMETRIC'};
			hit = false;

			for v = 1:numel(ok_values)
				if strcmp(ok_values{v},NormalizationType)
					hit = true;
					break;
				end
			end
			
			if (~hit)
				error('Allowed values: NormalizationType={%s, %s, %s, %s} ', ok_values{:})
			end

			self.NormalizationType = NormalizationType;
		end
	end	
end