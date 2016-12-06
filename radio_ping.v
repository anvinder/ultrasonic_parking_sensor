//////////////////////////////////////////////////////////////////////
// 	radio_ping.v
//////////////////////////////////////////////////////////////////////
//
//	-Ultrasonic Transmit Waveform Generator and Receiver
//	-For use with the NS73MFM Radio module 
//		-Creates CK, DA, LA signal bridge
//		-Generates tone to FM module, tone_en enabled
//	-Requires 32MHz clock
//	-Trigger: Positive-edge begins transmit process
//		-Fire and Forget, can be reset anytime after asserted
//		-Must be asserted for each transmit pulse emitted
//	-tx_pulse: Output transmit signal to ultrasonic transducer
//	-tx_duty: Monitor port for transmit pulse envelope
//	-rx_in: raw return from analog receiver stages
//	-rx_out: filtered digital representation of echo complex
//		-transmit-blanked
//	-rng_pwm: output signal output pulse-width representative 
//		  of range to closest target
//
//////////////////////////////////////////////////////////////////////
//	Creative Commons Attribution-ShareAlike 3.0
//////////////////////////////////////////////////////////////////////
//	10/21/10	G.E. Rogers		
//	http://majolsurf.net
//////////////////////////////////////////////////////////////////////


`define RECEIVE_BLANK 35000								//30000 = 1 foot
`define RECEIVE_HOLD 500
`define ARD_HOLDOFF 1000
`define ARD_MAX_RANGE 1000000
`define WAVEFORM_DUTY 195
`define TRANSMIT_DUTY 4000

module radio_ping(clk_32, tx_pulse, rx_in, rx_out, trigger, rng_pwm,
				ARD_CK, ARD_DA, ARD_LA, MOD_CK, MOD_DA, MOD_LA,
				tone, tone_en);

input clk_32;									//system clock 32MHz

input trigger;									//starts transmit process
inout tx_pulse;									//transmit pulse to transducer

input rx_in;									//unfilterd receiver input
output rx_out;									//filtered receiver output
output rng_pwm;									//pwm range data

output tone;
input tone_en;

input ARD_CK, ARD_DA, ARD_LA;
output MOD_CK, MOD_DA, MOD_LA;

wire MOD_CK = ARD_CK;
wire MOD_DA = ARD_DA;
wire MOD_LA = ARD_LA;


reg clk_16;
always @(posedge clk_32) clk_16 <= ~clk_16;

//////////////////////////////////////////////////////////////////////
// Waveform Generator 
//
//			-WAVEFORM_DUTY defines the waveform frequency.  Adjusting
//			this value tunes the output frequency.  The Maxbotix UT is
//			a 40kHz transducer.  Adjust this value and notice the very
//			narrow bandwidth of the transducer.  
//
//			196 x 2 = 392 waveform period
//	
//			clk_16 period = 0.0000000625			
//
//			392 x 0.0000000625 = 24.5us, 40.82kHz

reg waveform;	//40kHz
reg [7:0] wf_count;

always @(posedge clk_16) 
	if (wf_count == `WAVEFORM_DUTY)
		begin
			wf_count <= 0;
			waveform <= ~waveform;
		end
		
	else
		begin
			wf_count <= wf_count + 1'b1;
			waveform <= waveform;
		end


//////////////////////////////////////////////////////////////////////
// Tone Generator
//
//			-RECEIVE_BLANK is the time to disable receiver while
//			transmitter noise settles.
//

reg [8:0] tone_cnt;

reg tone_r;
always @(posedge wf_count[7]) 
	if (tone_cnt == 200) 
		begin
			tone_cnt <= 0;
			tone_r <= ~tone_r;
		end
	else 
		begin
			tone_cnt <= tone_cnt + 1'b1;
			tone_r <= tone_r;
		end

wire tone = (tone_r && tone_en);
	


//////////////////////////////////////////////////////////////////////
// Receiver -includes RX Blank
//
//			-RECEIVE_BLANK is the time to disable receiver while
//			transmitter noise settles.
//

reg [1:0] detect_r;
always @(posedge clk_16) detect_r <= {detect_r[0], rx_in};
wire detect = (detect_r == 2'b01);

reg rx_out;

always @(posedge clk_16)
  if (pri_count < `RECEIVE_BLANK) rx_out <= 0;
  else if (detect) rx_out <= 1;  
  else rx_out <= 0;
	
	
	
//////////////////////////////////////////////////////////////////////
// Range Pulse Width 
//
//			-Used for the Arduino to time the length rng_pwm stays
//			high.  
//
//			-ARD_HOLDOFF is the time that allows the Arduino to set
//			the transmitter trigger high and then enter into the pulse
//			measurement routine.  If this is set wrong the Arduino will
//			miss the rng_pwm low to high transition and hang.
//
//			-ARD_MAX_RANGE sets the maximum range before the next PRI
//			begins.  PRI is set by the Arduino.

reg rng_pwm;

always @(posedge clk_16)
	if (pri_count == `ARD_HOLDOFF) rng_pwm <= 1;
	else if (rx_out) rng_pwm <= 0;
	else if (pri_count == `ARD_MAX_RANGE) rng_pwm <= 0;
	else rng_pwm <= rng_pwm;
	
	
	
//////////////////////////////////////////////////////////////////////
// Transmit Pulse Generator
//
//			-TRIGGER from Arduino or other PRF generator starts the
//			single pulse transmit process.  PRI = pulse repetition
//			interval.  PRF = pulse repetition frequency.
//
//			-TX_DUTY defines the transmit pulse "envelope."  The tx
//			waveform is carried in this envelope.



// Trigger event detection
reg [1:0] trigger_r;
always @(posedge clk_16) trigger_r <= {trigger_r[0], trigger};
wire trigger_posedge = (trigger_r == 2'b01);


reg tx_enable;
reg tx_duty;		
reg [21:0] pri_count;

always @(posedge clk_16) 
	if (trigger_posedge) 
		begin
			tx_enable <= 1;
			tx_duty <= tx_duty;
			pri_count <= pri_count;
		end
	else if (tx_enable)
		begin
			if (pri_count == 1000000) 
				begin
					tx_enable <= 0;
					tx_duty <= tx_duty;
					pri_count <= 0;					
				end
			else if (pri_count == 0)
				begin
					tx_enable <= tx_enable;
					tx_duty <= 1;
					pri_count <= pri_count + 1'b1;
				end
			else if (pri_count == `TRANSMIT_DUTY)
				begin
					tx_enable <= tx_enable;
					tx_duty <= 0;
					pri_count <= pri_count + 1'b1;
				end
			else 
				begin
					tx_enable <= tx_enable;
					tx_duty <= tx_duty;
					pri_count <= pri_count + 1'b1;
				end
			end	
		else
			begin
				tx_enable <= tx_enable;
				tx_duty <= tx_duty;
				pri_count <= pri_count;
			end



//////////////////////////////////////////////////////////////////////
// Transmitter/Receiver Duplexer
//
//			-Used generate transmitted signal then enable the receiver
//			to listen for the echo both on the same transducer.
//	
//			-When tx_duty is high, the waveform generator is connected
//			to the transducer.  During this time the rx_in pin sees 
//			transmitted waveform.  rx_out is blanked so that it is not
//			propogated to the processing unit.
//
//			-When not transmitting the output port is connected to high
//			impedence to allow the transducer to act as a receiver.
//
//			-It should be noted here that the transmit pulse (tx_duty)
//			and waveform generator are not in sync.  Therefore there is
//			no phase coherence from transmit pulse to transmit pulse.

reg tx_pulse;

always @(posedge clk_16)
if (tx_duty) tx_pulse <= waveform;
else tx_pulse <= 1'hz;



endmodule





