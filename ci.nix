# HerculesCI config
let
  survey = import ./survey {};
in survey.working // survey.workingStackageExecutables
