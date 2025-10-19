namespace X.Subfolder.MoreTests

open Xunit
open System.Threading.Tasks

module A =

    [<Fact>]
    let ``My test in subfolder`` () =
        let fx x =
            let x = 1
            Assert.True(false)

        fx ()
