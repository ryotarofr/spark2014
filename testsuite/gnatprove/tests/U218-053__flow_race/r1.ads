package R1 with Abstract_State => (R1_State) is
   private
      package R2
        with Abstract_State => (R2_State with Part_Of => R1.R1_State) is
         task type T1; --@TASK_TERMINATION:FAIL
      end R2;
end R1;
