classdef NetworkedControlSystem < handle
    % This class represents a single networked control system, consisting
    % of (linear) plant and sensor, an actuator and a controller.
    
    %    This program is free software: you can redistribute it and/or modify
    %    it under the terms of the GNU General Public License as published by
    %    the Free Software Foundation, either version 3 of the License, or
    %    (at your option) any later version.
    %
    %    This program is distributed in the hope that it will be useful,
    %    but WITHOUT ANY WARRANTY; without even the implied warranty of
    %    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    %    GNU General Public License for more details.
    %
    %    You should have received a copy of the GNU General Public License
    %    along with this program.  If not, see <http://www.gnu.org/licenses/>.
    
    properties (GetAccess = public, SetAccess = immutable)
        name;
        samplingInterval; % in seconds, all components are clock-synchronous
        networkType@NetworkType;
    end
  
    properties (Access = public)
        sensor@NcsSensor;
        controller@NcsController;
        plant@NcsPlant;
    end
    
    properties (Access = private)
        plantState;
        plantMode;
        
        % statistics to record in each step (struct)
        statistics;
    end
    
    properties (Dependent, GetAccess = public)
        controlSequenceLength;
    end
    
    properties (Constant, Access = private)
         % which is a frequency of 10 Hz
        defaultSamplingTime = 0.1;
    end
    
    methods
        function sequenceLength = get.controlSequenceLength(this)
            sequenceLength = this.controller.controlSequenceLength;
        end
    end
       
    methods (Access = public)
        %% NetworkedControlSystem
        function this = NetworkedControlSystem(name, samplingInterval, networkType)
            % Class constructor.
            %
            % Parameters:
            %   >> name 
            %      Name or identifier for NCS.
            %
            %   >> samplingInterval (Positive Scalar, optional)
            %      A positive scalar denoting the sampling interval (in
            %      seconds) of the NCS. If none is passed, 0.1 is used.
            %
            %   >> networkType (NetworkType, optional)
            %      A constant from the enumeration describing the network
            %      type (e.g. TCP-like) that shall be used for this
            %      instance.
            %      If none is passed NetworkType.UdpLikeWithAcks is used.
            %
            % Returns:
            %   << this (NetworkedControlSystem)
            %      A new NetworkedControlSystem instance.
            switch nargin
                case 0
                    name = 'NCS';
                    samplingInterval = NetworkedControlSystem.defaultSamplingTime;
                    networkType = NetworkType.UdpLikeWithAcks;
                case 1
                    samplingInterval = NetworkedControlSystem.defaultSamplingTime;
                    networkType = NetworkType.UdpLikeWithAcks;
                case 2
                    if ~Checks.isPosScalar(samplingInterval)
                        error('NetworkedControlSystem:InvalidSamplingInterval', ...
                            '** <samplingInterval> must be a positive scalar. **');
                    end
                    networkType = NetworkType.UdpLikeWithAcks;
            end
            this.name = name;
            this.samplingInterval = samplingInterval;
            this.networkType = networkType;
        end
        
               
        %% initPlant
        function initPlant(this, plantState)
            % Set the initial plant state.
            %
            % Parameters:
            %   >> plantState (Vector or Distribution)
            %      A vector or a probability distribution of of appropriate dimension, i.e., the size
            %      equals the one expected by the plant.
            %      If a distribution is passed, the initial state is
            %      randomly drawn according to the given probability law.
            %
            this.checkPlant();
            this.checkController();
            if isa(plantState, 'Distribution')
                state = plantState.drawRndSamples(1);
            else
                state = plantState;
            end
            if ~isnumeric(state) || ~isvector(state) || length(state) ~= this.plant.dimState || ~all(isfinite(state))
                error('NetworkedControlSystem:InitPlant', ...
                    '** Cannot init plant: State must be a real-valued %d-dimensional vector or distribution **', ...
                    this.plant.dimState);
            end
             % store as column vector
            this.plantState = state(:);
            % also, set the initial true mode (maxMode)
            this.plantMode = this.controlSequenceLength + 1;%1; 
        end
        
        %% initStatisticsRecording
        function initStatisticsRecording(this, maxLoopSteps)
            % Initialize the recording of data to be gathered at each
            % time step, which are: true state, true mode, applied input,
            % number of used measurements, number of discarded
            % measurements, number of discarded control sequences.
            % 
            % In particular, memory is allocated for the given number of
            % time steps and the initial data (at k=0) are recorded.
            %
            % Parameters:
            %   >> maxLoopSteps (Positive integer)
            %      The maximum number of simulation time steps.
            %
            this.checkPlant();
            
            if ~Checks.isPosScalar(maxLoopSteps) || mod(maxLoopSteps, 1) ~= 0
                error('NetworkedControlSystem:InitStatisticsRecording', ...
                    '** Cannot init recording of statistics: <maxLoopSteps> must be a positive integer **');
            end
            this.statistics.trueStates = nan(this.plant.dimState, maxLoopSteps + 1);
            this.statistics.trueModes = nan(1, maxLoopSteps + 1);
            this.statistics.appliedInputs = nan(this.plant.dimInput, maxLoopSteps);
            this.statistics.numUsedMeasurements = nan(1, maxLoopSteps);
            this.statistics.numDiscardedMeasurements = nan(1, maxLoopSteps);
            this.statistics.numDiscardedControlSequences = nan(1, maxLoopSteps);
            %
            %this.statistics.estimates = nan(this.plant.dimState, maxLoopSteps + 1);
            %this.statistics.covariances = nan(this.plant.dimState, this.plant.dimState, maxLoopSteps + 1);
            
            % set the initial values (at timestep k=0)
            this.statistics.trueStates(:, 1) = this.plantState;
            %[this.statistics.estimates(:, 1), this.statistics.covariances(:, :, 1)] = this.filter.getPointEstimate();
            this.statistics.trueModes(1) = this.plantMode;
        end
        
        %% getStatistics
        function statistics = getStatistics(this)
            % Get the statistical data that has been recorded.
            %
            % Returns:
            %   << statistics (Struct)
            %      The statistical data.
            %
            statistics = this.statistics;
        end
        
        %% getQualityOfControl
        function currentQoC = getQualityOfControl(this, timestep)
            % Get the current quality of control (QoC).
            %
            % Parameters:
            %   >> timestep (Positive integer)
            %      The current time step, i.e., the integer yielding the
            %      current simulation time (in s) when multiplied by the
            %      loop's sampling interval.
            %
            % Returns:
            %   << currentQoC (Nonnegative scalar)
            %      The current QoC, which is simply the norm of the current
            %      plant true state, or, in a tracking task, the norm of
            %      the deviation from the current reference output.
                       
            % currently, simply express QoC in terms of norm of state
            % hence, a small value is desired
            this.checkPlant();
            currentQoC = this.controller.getCurrentQualityOfControl(this.plantState, timestep);
        end
        
        %% computeTotalControlCosts
        function costs = computeTotalControlCosts(this)
            this.checkController();
            
            costs = this.controller.computeCosts(this.statistics.trueStates, this.statistics.appliedInputs);
        end
        
        %% step
        function [inputSequence, measurement, controllerAck] = step(this, timestep, scPackets, caPackets, acPackets)
            % Execute a single time-triggered control cycle as described on
            % pages 36-37 in: 
            %   Jörg Fischer,
            %   Optimal sequence-based control of networked linear systems,
            %   Karlsruhe series on intelligent sensor-actuator-systems, Volume 15,
            %   KIT Scientific Publishing, 2015.
            %
            % Parameters:
            %   >> timestep (Positive integer)
            %      The current time step, i.e., the integer yielding the
            %      current simulation time (in s) when multiplied by the
            %      loop's sampling interval.
            %     
            %   >> scPackets (Array of DataPackets, might be empty)
            %      An array of DataPackets containing measurements taken and transmitted from the sensor.
            %
            %   >> caPackets (Array of DataPackets, might be empty)
            %      An array of DataPackets containing control sequences sent from the controller.
            %
            %   >> acPackets (Array of DataPackets, might be empty)
            %      An array of DataPackets containing ACKs returned from the actuator.
            %
            % Returns:
            %   << inputSequence (Matrix of size dimInput x controlSequenceLength, might be empty)
            %      The new control sequence computed by the controller, with the individual inputs column-wise arranged.
            %      Empty matrix is returned in case none is to be transmitted (e.g., when the controller is event-based).
            %
            %   << measurement (Column vector, might be empty)
            %      The new measurement taken by the sensor.
            %      Empty matrix is returned in case none is to be transmitted (e.g., when the sensor is event-based).
            %
            %   << controllerAck (Empty matrix or DataPacket)
            %      The ACK for the DataPacket within the given caPackets that has
            %      become active. An empty matrix is returned in case none
            %      became active.
            
            this.checkPlant();
            this.checkController();
            this.checkSensor();
 
            % take a measurement y_k
            measurement = this.sensor.step(this.plantState);
                        
            % do not pass the previous plant mode to the controller unless
            % network is TCP-like
            previousMode = [];
            if this.networkType == NetworkType.TcpLike
                previousMode = this.plantMode;
            end
            
            [inputSequence, numUsedMeas, numDiscardedMeas] ...
                = this.controller.step(timestep, scPackets, acPackets, previousMode);
       
            % update the recorded data accordingly
%             [this.statistics.estimates(:, timestep + 1), ...
%                 this.statistics.covariances(:, :, timestep + 1)] = this.filter.getPointEstimate();
            this.statistics.numUsedMeasurements(timestep) = numUsedMeas;
            this.statistics.numDiscardedMeasurements(timestep) = numDiscardedMeas;
            
            [controllerAck, numDiscardedSeq, actualInput, this.plantMode, newPlantState] ...
                = this.plant.step(timestep, caPackets, this.plantState);
                                 
            if this.networkType ~= NetworkType.UdpLikeWithAcks
                % we do not send ACKs back to the controller in case of
                % TCP-like or UDP-like communication
                controllerAck = [];
            end
 
            % record the number of discarded control packets            
            this.statistics.numDiscardedControlSequences(timestep) = numDiscardedSeq;
            % record the data about true input and state
            this.statistics.appliedInputs(:, timestep) = actualInput; % this input was applied at time k (u_k)
            this.statistics.trueModes(timestep + 1) = this.plantMode; % the mode theta_k
            this.statistics.trueStates(:, timestep + 1) = this.plantState; % store x_k
            
            this.plantState = newPlantState;
        end
       
    end
    
    methods(Access = private)
                
        %% checkController
        function checkController(this)
            if isempty(this.controller)
                error('NetworkedControlSystem:CheckController', ...
                    '** Controller has not been specified **');
            end
        end
                     
        %% checkPlant
        function checkPlant(this)
            if isempty(this.plant)
                error('NetworkedControlSystem:CheckPlant', ...
                    '** Plant has not been specified **');
            end
        end
        
        %% checkSensor
        function checkSensor(this)
            if isempty(this.sensor)
                error('NetworkedControlSystem:CheckSensor', ...
                    '** Sensor has not been specified **');
            end
        end
    end
end
