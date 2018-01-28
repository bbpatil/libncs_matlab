classdef NcsControllerWithFilter < NcsController
    % Wrapper class for controllers that require an external filter in an NCS to provide a consistent
    % interface.
    
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
    
    properties (SetAccess=immutable, GetAccess = public)
        filter@DelayedMeasurementsFilter;
        plantModel@SystemModel; 
        measModel@LinearMeasurementModel;
    end
    
    properties (Access = private)
        bufferedControlInputSequences;
        defaultInput;
    end
    
    methods (Access = public)
        %% NcsControllerWithFilter
        function this = NcsControllerWithFilter(controller, filter, plantModel, measModel, defaultInput)
            % Class constructor.
            %
            % Parameters:
            %   >> controller (SequenceBasedController instance)
            %      The controller to be utilized within the corresponding
            %      NCS.
            %
            %   >> filter (DelayedMeasurementsFilter instance)
            %      The filter employed to supply the given controller with
            %      state estimates.
            %
            %   >> plantModel (SystemModel instance)
            %      The system model utilized by the filter for prediction
            %      steps, which might be specifically tailored to the
            %      filter.
            %
            %   >> measModel (LinearMeasurementModel instance)
            %      The measurement model utilized by the filter for update
            %      steps, which might be specifically tailored to the
            %      filter.
            %
            %   >> defaultInput (Vector)
            %      The default input to be emplyoed by the actuator if its
            %      buffer runs empty.
            %
            % Returns:
            %   << this (NcsControllerWithFilter)
            %      A new NcsControllerWithFilter instance.
            %
            this = this@NcsController(controller);
                    
            this.filter = filter;
            this.plantModel = plantModel;
            this.measModel = measModel;
            this.defaultInput = defaultInput(:);
            
             this.bufferedControlInputSequences ...
                = repmat(this.defaultInput, [1 this.controlSequenceLength this.controlSequenceLength]);
        end
        
        %% step
        function [inputSequence, numUsedMeas, numDiscardedMeas] ...
                = step(this, timestep, scPackets, acPackets, plantMode)
            % we make use of a dedicated filter to obtain the state
            % estimate

            % first, update the estimate, i.e., obtain x_k
            [numUsedMeas, numDiscardedMeas, previousMode] = this.updateEstimate(scPackets, acPackets, timestep);
            
            this.bufferedControlInputSequences = circshift(this.bufferedControlInputSequences, 1, 3);
            % if previous true mode is unknown, some sort of certainty equivalence: use mode estimate
            % instead of true mode
            if ~isempty(plantMode)
                % should only happen in case of Tcp-like network
                previousMode = plantMode;
            elseif isempty(previousMode)
                 error('NcsControllerWithFilter:Step:MissingPreviousPlantMode', ...
                    '** Cannot compute U_k: Neither previous plant mode nor its estimate present **');
            end
            % compute the control inputs u_k, ..., u_{k+N}, i.e, sequence U_k
            % use (previous!) true mode (theta_{k-1}) or estimated mode of augmented system
            % and use xhat_k
            inputSequence = this.computeControlInputSequence(previousMode, timestep);
            % finally, update the buffer for the filter
            if ~isempty(inputSequence)
                this.bufferedControlInputSequences(:,:, 1) = inputSequence;
            else
                this.bufferedControlInputSequences(:,:, 1) ...
                    = repmat(this.defaultInput, 1, this.controlSequenceLength);
                 %fprintf('Do not send control input at time k = %d\n', timestep);
            end
        end
    end
    
    methods (Access = private)
        %% updateEstimate
        function [numUsedMeas, numDiscardedMeas, previousModeEstimate] = updateEstimate(this, scPackets, acPackets, timestep)
            % so far, only the DelayedIMMF is supported
            % distribute the possible inputs to all modes
            modeSpecificInputs = arrayfun(@(mode) this.bufferedControlInputSequences(:, mode, mode), ...
                1:this.controlSequenceLength, 'UniformOutput', false);
            % include the default input for the last mode 
            this.plantModel.setSystemInput([cell2mat(modeSpecificInputs) this.defaultInput]);
            
            % we need a special treatment for the DelayedModeIMMF
            if Checks.isClass(this.filter, 'DelayedModeIMMF')
                [numUsedMeas, numDiscardedMeas, previousModeEstimate] ...
                    = this.performUpdateEstimateDelayedModeIMMF(scPackets, acPackets, timestep);
            else
                [measurements, measDelays] = NcsController.processScPackets(scPackets);
                if ~isempty(measurements)
                    this.filter.step(this.plantModel, this.measModel, measurements, measDelays);
                    [numUsedMeas, numDiscardedMeas] = this.filter.getLastUpdateMeasurementData();
                else
                    % only perform a prediction
                    this.filter.predict(this.plantModel);
                    numUsedMeas = 0;
                    numDiscardedMeas = 0;
                end
                % all other filters do currently not provide an appropriate
                % estimate
                previousModeEstimate = [];
            end
        end
        
        %% performUpdateEstimateDelayedModeIMMF
        function [numUsedMeas, numDiscardedMeas, previousModeEstimate] = performUpdateEstimateDelayedModeIMMF(this, scPackets, acPackets, timestep)
            % we need a special treatment
            [modeObservations, modeDelays] = NcsControllerWithFilter.processAcPackets(timestep, acPackets);
            
            [measurements, measDelays] = NcsController.processScPackets(scPackets);
            this.filter.step(this.plantModel, this.measModel, ...
                measurements, measDelays, modeObservations, modeDelays);

            [numUsedMeas, numDiscardedMeas] = this.filter.getLastUpdateMeasurementData();
            previousModeEstimate = this.filter.getPreviousModeEstimate();
        end
       
        %% computeControlInputSequence
        function inputSequence = computeControlInputSequence(this, varargin)
            % Compute a sequence of control inputs to apply based on the most recent estimate of the associated filter.
            %
            % Parameters:
            %   >> varargin (Optional arguments)
            %      Any optional arguments for the controller, such as current time step (e.g. if the controller's horizon is not infinite) or 
            %      the previous (estimated) mode of the controllor-actuator-plant subsystem.
            %
            % Returns:
            %   << inputSequence (Matrix, might be empty)
            %      A matrix, where the elements of the sequence are column-wise arranged.
            %      The empty matrix is returned in case no sequence was
            %      created by the controller, for instance, if, in an
            %      event-triggered setting, none is to be transmitted.
            %      
            %
            inputSequence = ...
                this.reshapeInputSequence(this.controller.computeControlSequence(this.filter.getState(), varargin{:}));
        end
    end
    
    methods (Static, Access = private)
        %% processAcPackets
        function [modeObservations, modeDelays] = processAcPackets(timestep, acPackets)
            modeObservations = [];
            modeDelays = [];
            if numel(acPackets) ~= 0
                ackPayloads = cell(1, numel(acPackets));
                ackDelays = cell(1, numel(acPackets));
                [ackPayloads{:}] = acPackets(:).payload;
                [ackDelays{:}] = acPackets(:).packetDelay;
                % get the observed modes from the ACK packets
                ackedPacketTimes = cell2mat(ackPayloads);
                modeDelays = cell2mat(ackDelays);
                % get the time stamps of the ACK packets
                ackTimeStamps = timestep - modeDelays;
                
                modeObservations = ackTimeStamps - ackedPacketTimes + 1;
            end
        end
    end
end
