using PWDFT
using PWDFT.PsPot

function test_main()
  psp = PsPot_HGH(1, "Ge", "../LDA_HGH/32ge.4.hgh")
  info_PsPot_HGH(psp)
end

test_main()
