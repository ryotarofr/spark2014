-- Ada_eVoting: Toy electronic voting program in Ada

-- copyright 2012 David MENTR� <dmentre@linux-france.org>

--  Permission is hereby granted, free of charge, to any person or organization
--  obtaining a copy of the software and accompanying documentation covered by
--  this license (the "Software") to use, reproduce, display, distribute,
--  execute, and transmit the Software, and to prepare derivative works of the
--  Software, and to permit third-parties to whom the Software is furnished to
--  do so, all subject to the following:
--
--  The copyright notices in the Software and this entire statement, including
--  the above license grant, this restriction and the following disclaimer,
--  must be included in all copies of the Software, in whole or in part, and
--  all derivative works of the Software, unless such copies or derivative
--  works are solely in the form of machine-executable object code generated by
--  a source language processor.
--
--  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
--  FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
--  SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
--  FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
--  ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
--  DEALINGS IN THE SOFTWARE.

pragma SPARK_Mode (On);

package eVoting is

   subtype Candidate_Name_t is String(1 .. 70);
   NO_VOTE_ENTRY : constant String(1..7) := "No vote";

   -- FIXME: We should put as invariant that the list of candidates
   -- does not change once they are read

   -- FIXME: In the same way, we should specify that counters do not change
   -- once we have finished the voting phase

   type Program_Phase_t is (Setup_Phase, Voting_Phase, Counting_Phase);
   type Counter_Range_t is new Integer range 0..10_000;
   type Candidate_Number_t is range 0..20;
   type Total_Range_t is
     new Integer range
       0..(Integer(Counter_Range_t'Last) * Integer(Candidate_Number_T'Last+1));
   type Candidate_Name_Array_t is
     array (Candidate_Number_t) of Candidate_Name_t;
   type Counters_t is array (Candidate_Number_t) of Counter_Range_t;
   type Election_Result_t is array (Candidate_Number_t) of Boolean;

   procedure Read_Candidates
     (program_phase  :     Program_Phase_t;
      candidates     : out Candidate_Name_Array_t;
      last_candidate : out Candidate_Number_t)
   with Pre  => program_phase = Setup_Phase,
        Post => -- untouched entries should contain only spaces
                (for all i in last_candidate + 1 .. Candidate_Number_t'Last =>
                   (for all j in Candidate_Name_t'Range =>
                      candidates(i)(j) = ' ')),
        Exceptional_Cases => (others => True);

   procedure Print_A_Candidate
     (candidates   : Candidate_Name_Array_t;
      candidate_id : Candidate_Number_t);

   procedure Print_Candidates
     (candidates     : Candidate_Name_Array_t;
      last_candidate : Candidate_Number_t);

   procedure Vote_Setup
     (program_phase  :     Program_Phase_t;
      candidates     : out Candidate_Name_Array_t;
      last_candidate : out Candidate_Number_t)
   with Pre => program_phase = Setup_Phase,
        Exceptional_Cases => (others => True);

   procedure Get_Vote
     (program_phase  :     Program_Phase_t;
      candidates     :     Candidate_Name_Array_t;
      last_candidate :     Candidate_Number_t;
      chosen_vote    : out Candidate_Number_t)
   with Pre =>  program_phase = Voting_Phase,
        Post => chosen_vote <= last_candidate,
        Exceptional_Cases => (others => True);

   function Counters_Sum(counters : in Counters_t) return Natural;

   procedure Voting
     (program_phase   :        Program_Phase_t;
      candidates      :        Candidate_Name_Array_t;
      last_candidate  :        Candidate_Number_t;
      counters        : in out Counters_t;
      number_of_votes : in out Natural)
   -- FIXME: How to specify that input is only voter input from Get_Vote?
   with Pre  => program_phase = Voting_Phase and then
          (for all i in Candidate_Number_t'Range => counters(i) = 0) and then
          number_of_votes = 0,
        Post => (for all i in last_candidate + 1 .. Candidate_Number_t'Last =>
                       counters(i) = 0),
        Exceptional_Cases => (others => True);

   procedure Compute_Winner
     (program_phase  :     Program_Phase_t;
      last_candidate :     Candidate_Number_t;
      counters       :     Counters_t;
      winners        : out Election_Result_t)
   with Pre => program_phase = Counting_Phase,
        Post => (for all winner in Candidate_Number_t'Range =>
                   (for all i in Candidate_Number_t range 1 .. Last_Candidate =>
                      (if winners(winner) and not winners(i) then
                         counters(winner) > counters(i))
                         and then
                      (if winners(winner) and winners(i) then
                         counters(winner) = counters(i))))
                   and then
                (for all i in (last_candidate + 1)..Candidate_Number_t'Last =>
                   Winners(I) = False);

   procedure Compute_Print_Results
     (program_phase  : Program_Phase_t;
      candidates     : Candidate_Name_Array_t;
      last_candidate : Candidate_Number_t;
      counters       : Counters_t)
   with Pre => program_phase = Counting_Phase;

   procedure Do_Vote
     with Exceptional_Cases => (others => True);
end;
