(set-logic QF_LRA)
(set-info :status unsat)
(declare-fun x_39 () Bool)
(declare-fun x_83 () Bool)
(assert (not (<= (ite x_39 0.0 0.0) (ite x_83 0.0 0.0))))
(check-sat)
(exit)
