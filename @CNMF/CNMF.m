classdef CNMF < handle
   
    % Class for the CNMF object for standard 2p motion correction
    %% properties
    properties
        file = '';              % path to file
        Y;                      % raw data in X x Y ( x Z) x T format
        Yr;                     % raw data in 2d matrix XY(Z) X T format
        A;                      % spatial components of neurons
        b;                      % spatial components of background
        C;                      % temporal components of neurons
        f;                      % temporal components of backgrounds
        S;                      % neural activity
        Y_res;                  % residual signal (Y - AC - bf)
        R;                      % matrix of component residuals
        bl;                     % baseline of each component
        c1;                     % initial value of each component
        g;                      % discrete time constants for each component
        neuron_sn;              % noise level for each temporal component
        T;                      % number of timesteps
        dims;                   % dimensions of FOV
        d;                      % total number of pixels/voxels
        Cn;                     % correlation image
        cm;                     % center of mass for each component
        Coor;                   % neuron contours
        Df;                     % background for each component to normalize the filtered raw data
        C_df;                   % temporal components of neurons and background normalized
        options;                % options for model fitting
        gSig = [5,5];           % half size of neuron
        P;                      % some estimated parameters
        fr = 30;                % frame rate
        K;                      % number of components
        nb = 1;                 % number of background components
        gnb = 2;                % number of global background components
        p = 0;                  % order of AR system
        minY;                   % minimum data value
        nd;                     % FOV dimensionality (2d or 3d)
        keep_cnn;               % CNN classifier acceptance
        val_cnn;                % CNN classifier value
        rval_space;             % correlation in space
        rval_time;              % correlation in time
        max_pr;                 % max_probability
        sizeA;                  % size of component
        keep_eval;              % evaluate components acceptance
        fitness;                % exceptionality measure
        fitness_delta;          
        A_throw;                % rejected spatial components
        C_throw;                % rejected temporal components
        S_throw;                % neural activity of rejected traces
        R_throw;                % residuals of rejected components
        ind_keep;               % selected components (binary vector)
        ind_throw;              % rejected components (binary vector)
        merged_ROIs;            % indeces of merged components
        CI;                     % correlation image
        Cdec; 
        Pdec; 
        Sdec;
        srt;
        Ybg;        
        indicator = 'GCaMP6f';  
        kernel;        
        kernels;
    end
    
    methods
        
        %% construct object and set options
        function obj = CNM(varargin)
            obj.options = CNMFSetParms();
            if nargin>0
                obj.options = CNMFSetParms(obj.options, varargin{:});
            end
        end
        
        %% read file and set dimensionality variables
        function read_file(obj,sframe,num2read)
            obj.Y = read_file(obj.file,sframe,num2read);
            if ~isa(obj.Y,'single')    
                obj.Y = single(obj.Y);  
            end
            obj.minY = min(obj.Y(:));
            obj.Y = obj.Y - obj.minY;                             % make data non-negative
            obj.nd = ndims(obj.Y)-1;                              
            dimsY = size(obj.Y);
            obj.T = dimsY(end);
            obj.dims = dimsY(1:end-1);
            obj.d = prod(obj.dims);
            obj.Yr = reshape(obj.Y,obj.d,obj.T);
            obj.options.d1 = obj.dims(1);
            obj.options.d2 = obj.dims(2);
            if obj.nd > 2; obj.options.d3 = obj.dims(3); end
        end
        
        %% update options
        function optionsSet(obj, varargin)
            obj.options = CNMFSetParms(obj.options, varargin{:});
        end
        
        %% data preprocessing
        function preprocess(obj)
            [obj.P,obj.Y] = preprocess_data(obj.Y,obj.p,obj.options);
        end        
        
        %% fast initialization
        function initComponents(obj, K, tau)
            [obj.A, obj.C, obj.b, obj.f, obj.cm] = initialize_components(obj.Y, K, tau, obj.options);
            obj.gSig = tau;
            obj.K = K;
        end
        
        %% update spatial components
        function updateSpatial(obj)        
            if strcmpi(obj.options.spatial_method,'regularized')
                A_ = [obj.A, obj.b];
            else
                A_ = obj.A;
            end
            [obj.A, obj.b, obj.C] = update_spatial_components(obj.Yr, obj.C, obj.f, A_, obj.P, obj.options);
        end
        
        %% update temporal components
        function updateTemporal(obj,p)
            if ~isempty(p); obj.P.p = p; else obj.P.p = CNM.p; end
            [obj.C, obj.f, obj.P, obj.S,obj.R] = update_temporal_components(...
                obj.Yr, obj.A, obj.b, obj.C, obj.f, obj.P, obj.options);
            obj.bl = cell2mat(obj.P.b);
            obj.c1 = cell2mat(obj.P.c1);
            obj.g = obj.P.gn;
            obj.neuron_sn = cell2mat(obj.P.neuron_sn);
        end
        
        %% merge components
        function merge(obj)
            [obj.A, obj.C, obj.K, obj.merged_ROIs, obj.P, obj.S] = merge_components(...
                obj.Yr,obj.A, [], obj.C, [], obj.P,obj.S, obj.options);
        end 
        
        %% extract DF_F
        function extractDFF(obj)
            [obj.C_df,~] = extract_DF_F(obj.Yr,obj.A,obj.C,obj.P,obj.options);
        end

        %% CNN classifier
        function CNNClassifier(obj,classifier)
            [obj.keep_cnn,obj.val_cnn] = cnn_classifier(obj.A,obj.dims,classifier,obj.options.cnn_thr);            
        end
        
        %% evaluate components
        function evaluateComponents(obj)
            [obj.rval_space,obj.rval_time,obj.max_pr,obj.sizeA,obj.keep_eval] = classify_components(...
                obj.Y,obj.A,obj.C,obj.b,obj.f,obj.R,obj.options);
        end

        %% keep components
        function keepComponents(obj,ind_keep)
            if ~exist('ind_keep','var')
                obj.ind_keep = obj.keep_eval & obj.keep_cnn;
            else
                obj.ind_keep = ind_keep;
            end
            obj.ind_throw = ~obj.ind_keep;
            obj.A_throw = obj.A(obj.ind_throw,:);
            obj.C_throw = obj.C(obj.ind_throw,:);
            obj.S_throw = obj.S(obj.ind_throw,:);
            obj.R_throw = obj.R(obj.ind_throw,:);
            obj.A = obj.A(:,obj.ind_keep);
            obj.C = obj.C(obj.ind_keep,:);
            obj.S = obj.S(obj.ind_keep,:);
            obj.R = obj.R(obj.ind_keep,:);
            obj.bl = obj.bl(obj.ind_keep);
            obj.c1 = obj.c1(obj.ind_keep);
            obj.neuron_sn = obj.neuron_sn(obj.ind_keep);
            obj.g = obj.g(obj.ind_keep);
        end
        
        %% normalize components
        function normalize(obj)
            nA = sqrt(sum(obj.A.^2,1));
            obj.A = bsxfun(@times, obj.A, 1./nA);
            obj.C = bsxfun(@times, obj.C, nA');
            if ~isempty(obj.S)
                obj.S = bsxfun(@times, obj.S, nA');
            end
            if ~isempty(obj.R)
                obj.R = bsxfun(@times, obj.R, nA');
            end
            nB = sqrt(sum(obj.b.^2,1));
            obj.b = bsxfun(@times, obj.b, 1./nB);
            obj.f = bsxfun(@times, obj.f, nB');
        end
           
        %% compute residuals
        function compute_residuals(obj)
            AA = obj.A'*obj.A;
            AY = mm_fun(obj.A,obj.Y);
            nA2 = sum(obj.A.^2,1);
            obj.R = bsxfun(@times, AY - AA*obj.C - (obj.A'*obj.b)*obj.f,1./nA2);
        end
        
        
        %% correlation image
        function correlationImage(obj)
            obj.CI = correlation_image_max(obj.Y);
        end
        

        %% plot components GUI
        function plotComponentsGUI(obj)
            if or(isempty(obj.CI), ~exist('CI', 'var') )
                %obj.CI = correlation_image_max(obj.Y);
                correlationImage(obj);
            end
            plot_components_GUI(obj.Yr,obj.A,obj.C,obj.b,obj.f,obj.CI,obj.options)
        end
                
    end
end